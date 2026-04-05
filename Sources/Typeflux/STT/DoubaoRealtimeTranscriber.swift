import AVFoundation
import Compression
import Darwin
import Foundation

final class DoubaoRealtimeTranscriber: RecordingPrewarmingTranscriber {
    private let settingsStore: SettingsStore
    private let connectionCoordinator = DoubaoPreparedConnectionCoordinator()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    static func testConnection(appID: String, accessToken: String, resourceID: String) async throws -> String {
        let trimmedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResourceID = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAppID.isEmpty else {
            throw NSError(
                domain: "DoubaoRealtimeTranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Doubao App ID is not configured."],
            )
        }

        guard !trimmedAccessToken.isEmpty else {
            throw NSError(
                domain: "DoubaoRealtimeTranscriber",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Doubao access token is not configured."],
            )
        }

        return try await DoubaoConnectionTester.verify(
            appID: trimmedAppID,
            accessToken: trimmedAccessToken,
            resourceID: trimmedResourceID.isEmpty ? "volc.seedasr.sauc.duration" : trimmedResourceID,
        )
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func prepareForRecording() async {
        guard let configuration = currentConfiguration() else { return }
        do {
            _ = try await connectionCoordinator.prepareConnection(
                appID: configuration.appID,
                accessToken: configuration.accessToken,
                resourceID: configuration.resourceID,
            )
        } catch {
            NetworkDebugLogger.logError(context: "Doubao realtime preconnect failed", error: error)
        }
    }

    func cancelPreparedRecording() async {
        await connectionCoordinator.cancelPreparedConnection()
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        guard let configuration = currentConfiguration() else {
            throw NSError(
                domain: "DoubaoRealtimeTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Doubao credentials are not configured."],
            )
        }

        let pcmData = try DoubaoAudioConverter.convert(url: audioFile.fileURL)
        let hotwords = VocabularyStore.activeTerms()

        return try await DoubaoRealtimeSession.run(
            pcmData: pcmData,
            appID: configuration.appID,
            accessToken: configuration.accessToken,
            resourceID: configuration.resourceID,
            hotwords: hotwords,
            connectionCoordinator: connectionCoordinator,
            onUpdate: onUpdate,
        )
    }

    private func currentConfiguration() -> DoubaoConnectionConfiguration? {
        let appID = settingsStore.doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = settingsStore.doubaoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceID = settingsStore.doubaoResourceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appID.isEmpty else { return nil }
        guard !accessToken.isEmpty else { return nil }
        return DoubaoConnectionConfiguration(
            appID: appID,
            accessToken: accessToken,
            resourceID: resourceID.isEmpty ? "volc.seedasr.sauc.duration" : resourceID,
        )
    }
}

private struct DoubaoConnectionConfiguration: Equatable {
    let appID: String
    let accessToken: String
    let resourceID: String
}

private final class DoubaoPreparedConnection {
    let configuration: DoubaoConnectionConfiguration
    let urlSession: URLSession
    let socketTask: URLSessionWebSocketTask

    init(
        configuration: DoubaoConnectionConfiguration,
        urlSession: URLSession,
        socketTask: URLSessionWebSocketTask,
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.socketTask = socketTask
    }

    func close() {
        socketTask.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }
}

private actor DoubaoPreparedConnectionCoordinator {
    private var preparedConnection: DoubaoPreparedConnection?

    func prepareConnection(
        appID: String,
        accessToken: String,
        resourceID: String,
    ) async throws -> DoubaoPreparedConnection {
        let configuration = DoubaoConnectionConfiguration(
            appID: appID,
            accessToken: accessToken,
            resourceID: resourceID,
        )

        if let preparedConnection, preparedConnection.configuration == configuration {
            return preparedConnection
        }

        preparedConnection?.close()
        let connection = try await DoubaoConnectionFactory.open(configuration: configuration)
        preparedConnection = connection
        return connection
    }

    func takePreparedConnection(
        appID: String,
        accessToken: String,
        resourceID: String,
    ) -> DoubaoPreparedConnection? {
        let configuration = DoubaoConnectionConfiguration(
            appID: appID,
            accessToken: accessToken,
            resourceID: resourceID,
        )
        guard let preparedConnection, preparedConnection.configuration == configuration else {
            return nil
        }
        self.preparedConnection = nil
        return preparedConnection
    }

    func cancelPreparedConnection() {
        preparedConnection?.close()
        preparedConnection = nil
    }
}

private enum DoubaoConnectionFactory {
    static func open(configuration: DoubaoConnectionConfiguration) async throws -> DoubaoPreparedConnection {
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        request.setValue(configuration.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(configuration.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        NetworkDebugLogger.logRequest(request, bodyDescription: "<websocket handshake>")
        NetworkDebugLogger.logWebSocketEvent(
            provider: "Doubao Realtime ASR",
            phase: "connect",
            details: "resourceID=\(configuration.resourceID)",
        )

        let delegate = DoubaoWSDelegate()
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socketTask = urlSession.webSocketTask(with: request)
        socketTask.resume()

        do {
            try await delegate.waitUntilOpen(timeout: .seconds(10))
            NetworkDebugLogger.logWebSocketEvent(provider: "Doubao Realtime ASR", phase: "open")
            return DoubaoPreparedConnection(
                configuration: configuration,
                urlSession: urlSession,
                socketTask: socketTask,
            )
        } catch {
            socketTask.cancel(with: .normalClosure, reason: nil)
            urlSession.invalidateAndCancel()
            throw error
        }
    }
}

private enum DoubaoAudioConverter {
    static let targetSampleRate: Double = 16000
    static let chunkSize: Int = 3200

    static func convert(url: URL) throws -> Data {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let totalSourceFrames = AVAudioFrameCount(sourceFile.length)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true,
        ) else {
            throw NSError(
                domain: "DoubaoAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."],
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "DoubaoAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."],
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "DoubaoAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."],
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "DoubaoAudioConverter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate target buffer."],
            )
        }

        var hasProvidedInput = false
        var convertError: NSError?
        let status = converter.convert(to: targetBuffer, error: &convertError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let convertError { throw convertError }
        guard status != .error else {
            throw NSError(
                domain: "DoubaoAudioConverter",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."],
            )
        }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(targetBuffer.frameLength) * bytesPerFrame
        guard let channelData = targetBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }
}

private enum DoubaoConnectionTester {
    static func verify(appID: String, accessToken: String, resourceID: String) async throws -> String {
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        NetworkDebugLogger.logRequest(request, bodyDescription: "<websocket handshake>")
        NetworkDebugLogger.logWebSocketEvent(provider: "Doubao Realtime ASR", phase: "connect", details: "resourceID=\(resourceID)")

        let delegate = DoubaoWSDelegate()
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socketTask = urlSession.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .normalClosure, reason: nil)
            urlSession.invalidateAndCancel()
        }

        try await delegate.waitUntilOpen(timeout: .seconds(10))
        NetworkDebugLogger.logWebSocketEvent(provider: "Doubao Realtime ASR", phase: "open")

        let payload = DoubaoProtocol.buildClientRequest(uid: UUID().uuidString, hotwords: [])
        let requestMessage = DoubaoProtocol.encodeMessage(
            header: DoubaoHeader(
                messageType: .fullClientRequest,
                flags: .noSequence,
                serialization: .json,
                compression: .none,
            ),
            payload: payload,
        )
        NetworkDebugLogger.logWebSocketEvent(
            provider: "Doubao Realtime ASR",
            phase: "send",
            details: "client_request",
        )
        try await socketTask.send(.data(requestMessage))

        do {
            _ = try await firstServerMessage(from: socketTask, timeout: .seconds(2))
        } catch is DoubaoConnectionTestTimeout {
            // Some valid connections don't emit a server message until audio arrives.
            return "WebSocket connected."
        }

        return "WebSocket connected."
    }

    private static func firstServerMessage(
        from socketTask: URLSessionWebSocketTask,
        timeout: Duration,
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let message = try await socketTask.receive()
                guard let data = messageData(from: message) else {
                    throw NSError(
                        domain: "DoubaoConnectionTester",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Received an empty Doubao server message."],
                    )
                }
                let header = try DoubaoHeader.decode(from: data)
                if header.messageType == .serverError {
                    throw DoubaoProtocol.decodeServerError(data)
                }
                return data
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DoubaoConnectionTestTimeout()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return string.data(using: .utf8)
        @unknown default:
            return nil
        }
    }
}

private struct DoubaoConnectionTestTimeout: Error {}

private actor DoubaoRealtimeSession {
    static func run(
        pcmData: Data,
        appID: String,
        accessToken: String,
        resourceID: String,
        hotwords: [String],
        connectionCoordinator: DoubaoPreparedConnectionCoordinator,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let session = DoubaoRealtimeSession(
            pcmData: pcmData,
            appID: appID,
            accessToken: accessToken,
            resourceID: resourceID,
            hotwords: hotwords,
            connectionCoordinator: connectionCoordinator,
            onUpdate: onUpdate,
        )
        return try await session.execute()
    }

    private let pcmData: Data
    private let appID: String
    private let accessToken: String
    private let resourceID: String
    private let hotwords: [String]
    private let connectionCoordinator: DoubaoPreparedConnectionCoordinator
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void

    private var didFinish = false
    private var sessionError: Error?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var lastSnapshot = TranscriptionSnapshot(text: "", isFinal: false)
    private var activeConnection: DoubaoPreparedConnection?
    private var receiveTask: Task<Void, Never>?

    private init(
        pcmData: Data,
        appID: String,
        accessToken: String,
        resourceID: String,
        hotwords: [String],
        connectionCoordinator: DoubaoPreparedConnectionCoordinator,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) {
        self.pcmData = pcmData
        self.appID = appID
        self.accessToken = accessToken
        self.resourceID = resourceID
        self.hotwords = hotwords
        self.connectionCoordinator = connectionCoordinator
        self.onUpdate = onUpdate
    }

    private func execute() async throws -> String {
        defer {
            receiveTask?.cancel()
            activeConnection?.close()
            activeConnection = nil
        }

        try await prepareActiveConnection(preferPrepared: true)

        let payload = DoubaoProtocol.buildClientRequest(uid: UUID().uuidString, hotwords: hotwords)
        let requestMessage = DoubaoProtocol.encodeMessage(
            header: DoubaoHeader(
                messageType: .fullClientRequest,
                flags: .noSequence,
                serialization: .json,
                compression: .none,
            ),
            payload: payload,
        )
        NetworkDebugLogger.logWebSocketEvent(
            provider: "Doubao Realtime ASR",
            phase: "send",
            details: "client_request hotwords=\(hotwords.count)",
        )
        try await sendWithRetry(.data(requestMessage), description: "client_request")

        var offset = 0
        var chunkCount = 0
        while offset < pcmData.count {
            let end = min(offset + DoubaoAudioConverter.chunkSize, pcmData.count)
            let chunk = pcmData[offset ..< end]
            try await sendWithRetry(
                .data(DoubaoProtocol.encodeAudioPacket(audioData: Data(chunk), isLast: false)),
                description: "audio_chunk_\(chunkCount + 1)",
            )
            offset = end
            chunkCount += 1
        }
        NetworkDebugLogger.logWebSocketEvent(
            provider: "Doubao Realtime ASR",
            phase: "send",
            details: "audio_chunks=\(chunkCount) audio_bytes=\(pcmData.count)",
        )
        NetworkDebugLogger.logWebSocketEvent(provider: "Doubao Realtime ASR", phase: "send", details: "audio_end")
        try await sendWithRetry(
            .data(DoubaoProtocol.encodeAudioPacket(audioData: Data(), isLast: true)),
            description: "audio_end",
        )

        try await waitForCompletion()

        let finalText = lastSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty, !lastSnapshot.isFinal {
            await onUpdate(TranscriptionSnapshot(text: finalText, isFinal: true))
        }
        return finalText
    }

    private func prepareActiveConnection(preferPrepared: Bool) async throws {
        if preferPrepared,
           let preparedConnection = await connectionCoordinator.takePreparedConnection(
               appID: appID,
               accessToken: accessToken,
               resourceID: resourceID,
           )
        {
            activeConnection = preparedConnection
        } else {
            activeConnection = try await DoubaoConnectionFactory.open(
                configuration: DoubaoConnectionConfiguration(
                    appID: appID,
                    accessToken: accessToken,
                    resourceID: resourceID,
                ),
            )
        }

        guard let socketTask = activeConnection?.socketTask else {
            throw NSError(
                domain: "DoubaoRealtimeSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Doubao WebSocket connection is unavailable."],
            )
        }

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socketTask: socketTask)
        }
    }

    private func sendWithRetry(
        _ message: URLSessionWebSocketTask.Message,
        description: String,
    ) async throws {
        let retryDelays: [Duration] = [.zero, .milliseconds(120), .milliseconds(300)]

        for (attempt, delay) in retryDelays.enumerated() {
            if attempt > 0 {
                try await Task.sleep(for: delay)
            }

            do {
                guard let socketTask = activeConnection?.socketTask else {
                    throw NSError(
                        domain: "DoubaoRealtimeSession",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Doubao WebSocket connection was not ready."],
                    )
                }
                try await socketTask.send(message)
                return
            } catch {
                guard isRetriableSocketConnectionError(error), attempt < retryDelays.count - 1 else {
                    throw error
                }

                NetworkDebugLogger.logError(
                    context: "Doubao realtime send \(description) failed before socket was ready; retrying",
                    error: error,
                )
            }
        }
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                guard let data = messageData(from: message) else { continue }
                NetworkDebugLogger.logWebSocketEvent(
                    provider: "Doubao Realtime ASR",
                    phase: "receive",
                    details: describeInboundMessage(data),
                )
                try await handleMessage(data)
            } catch {
                if Task.isCancelled { break }
                if didFinish {
                    break
                }
                NetworkDebugLogger.logError(context: "Doubao realtime receive loop failed", error: error)
                if lastSnapshot.text.isEmpty {
                    signalError(error)
                } else {
                    finish()
                }
                break
            }
        }
    }

    private func handleMessage(_ data: Data) async throws {
        let header = try DoubaoHeader.decode(from: data)
        if header.messageType == .serverError {
            if !lastSnapshot.text.isEmpty {
                NetworkDebugLogger.logWebSocketEvent(
                    provider: "Doubao Realtime ASR",
                    phase: "server_error_after_text",
                    details: NetworkDebugLogger.describe(error: DoubaoProtocol.decodeServerError(data)),
                )
                finish()
                return
            }
            let error = DoubaoProtocol.decodeServerError(data)
            NetworkDebugLogger.logWebSocketEvent(
                provider: "Doubao Realtime ASR",
                phase: "server_error",
                details: NetworkDebugLogger.describe(error: error),
            )
            throw error
        }

        let response = try DoubaoProtocol.decodeServerResponse(data)
        let snapshot = response.snapshot
        guard !snapshot.text.isEmpty, snapshot.text != lastSnapshot.text || snapshot.isFinal != lastSnapshot.isFinal else {
            if snapshot.isFinal {
                NetworkDebugLogger.logWebSocketEvent(provider: "Doubao Realtime ASR", phase: "final")
                finish()
            }
            return
        }

        lastSnapshot = snapshot
        NetworkDebugLogger.logWebSocketEvent(
            provider: "Doubao Realtime ASR",
            phase: snapshot.isFinal ? "final" : "partial",
            details: "text_length=\(snapshot.text.count)",
        )
        await onUpdate(snapshot)
        if snapshot.isFinal {
            finish()
        }
    }

    private func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return string.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func waitForCompletion() async throws {
        if didFinish { return }
        if let sessionError { throw sessionError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func signalError(_ error: Error) {
        guard sessionError == nil else { return }
        sessionError = error
        finishContinuation?.resume(throwing: error)
        finishContinuation = nil
    }

    private func describeInboundMessage(_ data: Data) -> String {
        guard let header = try? DoubaoHeader.decode(from: data) else {
            return "<\(data.count) bytes invalid_header>"
        }

        return "type=\(header.messageType) flags=\(header.flags) bytes=\(data.count)"
    }

    private func isRetriableSocketConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOTCONN) {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("socket is not connected") || message.contains("not connected")
    }
}

private actor DoubaoWSDelegateState {
    private var isOpen = false
    private var openContinuation: CheckedContinuation<Void, Error>?

    func markOpen() {
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }

    func markFailed(_ error: Error) {
        openContinuation?.resume(throwing: error)
        openContinuation = nil
    }

    func waitUntilOpen(timeout: Duration) async throws {
        if isOpen { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { await self.store(continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: "DoubaoWSDelegate",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Doubao WebSocket handshake timed out."],
                )
            }

            try await group.next()
            group.cancelAll()
        }
    }

    private func store(continuation: CheckedContinuation<Void, Error>) {
        openContinuation = continuation
    }
}

private final class DoubaoWSDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let state = DoubaoWSDelegateState()

    func waitUntilOpen(timeout: Duration) async throws {
        try await state.waitUntilOpen(timeout: timeout)
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?,
    ) {
        Task {
            await state.markOpen()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?,
    ) {
        guard let error else { return }
        Task { await state.markFailed(error) }
    }
}

enum DoubaoMessageType: UInt8 {
    case fullClientRequest = 0b0001
    case audioOnlyRequest = 0b0010
    case serverResponse = 0b1001
    case serverError = 0b1111
}

enum DoubaoMessageFlags: UInt8 {
    case noSequence = 0b0000
    case positiveSequence = 0b0001
    case lastPacketNoSequence = 0b0010
    case negativeSequenceLast = 0b0011
    case asyncFinal = 0b0100

    var hasSequence: Bool {
        self == .positiveSequence || self == .negativeSequenceLast
    }
}

enum DoubaoSerialization: UInt8 {
    case none = 0b0000
    case json = 0b0001
}

enum DoubaoCompression: UInt8 {
    case none = 0b0000
    case gzip = 0b0001
}

struct DoubaoHeader: Equatable {
    var version: UInt8 = 0b0001
    var headerSize: UInt8 = 0b0001
    var messageType: DoubaoMessageType
    var flags: DoubaoMessageFlags
    var serialization: DoubaoSerialization
    var compression: DoubaoCompression
    var reserved: UInt8 = 0

    func encode() -> Data {
        var data = Data(count: 4)
        data[0] = (version << 4) | (headerSize & 0x0F)
        data[1] = (messageType.rawValue << 4) | (flags.rawValue & 0x0F)
        data[2] = (serialization.rawValue << 4) | (compression.rawValue & 0x0F)
        data[3] = reserved
        return data
    }

    static func decode(from data: Data) throws -> DoubaoHeader {
        guard data.count >= 4 else { throw DoubaoProtocolError.headerTooShort }

        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]
        let byte2 = data[data.startIndex + 2]
        let byte3 = data[data.startIndex + 3]

        guard let messageType = DoubaoMessageType(rawValue: (byte1 >> 4) & 0x0F) else {
            throw DoubaoProtocolError.unknownMessageType((byte1 >> 4) & 0x0F)
        }
        guard let flags = DoubaoMessageFlags(rawValue: byte1 & 0x0F) else {
            throw DoubaoProtocolError.unknownFlags(byte1 & 0x0F)
        }
        guard let serialization = DoubaoSerialization(rawValue: (byte2 >> 4) & 0x0F) else {
            throw DoubaoProtocolError.unknownSerialization((byte2 >> 4) & 0x0F)
        }
        guard let compression = DoubaoCompression(rawValue: byte2 & 0x0F) else {
            throw DoubaoProtocolError.unknownCompression(byte2 & 0x0F)
        }

        return DoubaoHeader(
            version: (byte0 >> 4) & 0x0F,
            headerSize: byte0 & 0x0F,
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            reserved: byte3,
        )
    }
}

enum DoubaoProtocolError: Error, LocalizedError {
    case headerTooShort
    case unknownMessageType(UInt8)
    case unknownFlags(UInt8)
    case unknownSerialization(UInt8)
    case unknownCompression(UInt8)
    case invalidPayload
    case decompressionFailed
    case serverError(code: Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case let .serverError(code, message):
            message ?? "Doubao ASR server error (\(code ?? -1))."
        case .headerTooShort:
            "Doubao ASR response header is too short."
        case .invalidPayload:
            "Doubao ASR response payload is invalid."
        case .decompressionFailed:
            "Failed to decompress Doubao ASR payload."
        case let .unknownMessageType(value):
            "Unknown Doubao ASR message type: \(value)."
        case let .unknownFlags(value):
            "Unknown Doubao ASR message flags: \(value)."
        case let .unknownSerialization(value):
            "Unknown Doubao ASR serialization type: \(value)."
        case let .unknownCompression(value):
            "Unknown Doubao ASR compression type: \(value)."
        }
    }
}

struct DoubaoUtterance: Equatable {
    let text: String
    let definite: Bool
}

struct DoubaoServerResponse {
    let snapshot: TranscriptionSnapshot
    let utterances: [DoubaoUtterance]
}

enum DoubaoProtocol {
    static func buildClientRequest(
        uid: String,
        hotwords: [String],
    ) -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_punc": true,
            "enable_ddc": true,
            "enable_nonstream": true,
            "show_utterances": true,
            "result_type": "full",
            "end_window_size": 3000,
            "force_to_speech_time": 1000,
        ]

        if let context = buildContextString(hotwords: hotwords) {
            request["context"] = context
        }

        let payload: [String: Any] = [
            "user": ["uid": uid],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            ],
            "request": request,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func encodeMessage(
        header: DoubaoHeader,
        payload: Data,
        sequenceNumber: Int32? = nil,
    ) -> Data {
        var message = header.encode()
        if let sequenceNumber {
            var sequence = sequenceNumber.bigEndian
            message.append(Data(bytes: &sequence, count: 4))
        }
        var size = UInt32(payload.count).bigEndian
        message.append(Data(bytes: &size, count: 4))
        message.append(payload)
        return message
    }

    static func encodeAudioPacket(audioData: Data, isLast: Bool) -> Data {
        let header = DoubaoHeader(
            messageType: .audioOnlyRequest,
            flags: isLast ? .lastPacketNoSequence : .noSequence,
            serialization: .none,
            compression: .none,
        )
        return encodeMessage(header: header, payload: audioData)
    }

    static func decodeServerResponse(_ data: Data) throws -> DoubaoServerResponse {
        let header = try DoubaoHeader.decode(from: data)
        let headerBytes = Int(header.headerSize) * 4
        var offset = headerBytes

        if header.flags.hasSequence {
            offset += 4
        }

        guard data.count >= offset + 4 else {
            throw DoubaoProtocolError.invalidPayload
        }

        let sizeRange = data.startIndex + offset ..< data.startIndex + offset + 4
        let payloadSize = Int(UInt32(bigEndian: data[sizeRange].withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4

        guard data.count >= offset + payloadSize else {
            throw DoubaoProtocolError.invalidPayload
        }

        var payload = Data(data[data.startIndex + offset ..< data.startIndex + offset + payloadSize])
        if header.compression == .gzip {
            payload = try gzipDecompress(payload)
        }
        guard header.serialization == .json else {
            throw DoubaoProtocolError.invalidPayload
        }
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DoubaoProtocolError.invalidPayload
        }

        let result = json["result"] as? [String: Any]
        let text = (result?["text"] as? String ?? json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let utteranceObjects = (result?["utterances"] as? [[String: Any]]) ?? (json["utterances"] as? [[String: Any]]) ?? []
        let utterances = utteranceObjects.map {
            DoubaoUtterance(
                text: ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                definite: $0["definite"] as? Bool ?? false,
            )
        }

        let confirmed = utterances.filter(\.definite).map(\.text).filter { !$0.isEmpty }
        let partial = utterances.last(where: { !$0.definite && !$0.text.isEmpty })?.text ?? ""
        let authoritative = text.isEmpty ? (confirmed + (partial.isEmpty ? [] : [partial])).joined() : text
        return DoubaoServerResponse(
            snapshot: TranscriptionSnapshot(
                text: authoritative,
                isFinal: header.flags == .asyncFinal,
            ),
            utterances: utterances,
        )
    }

    static func decodeServerError(_ data: Data) -> Error {
        do {
            let header = try DoubaoHeader.decode(from: data)
            let headerBytes = Int(header.headerSize) * 4
            var offset = headerBytes
            if header.flags.hasSequence {
                offset += 4
            }
            guard data.count >= offset + 4 else { return DoubaoProtocolError.invalidPayload }
            let sizeRange = data.startIndex + offset ..< data.startIndex + offset + 4
            let payloadSize = Int(UInt32(bigEndian: data[sizeRange].withUnsafeBytes { $0.load(as: UInt32.self) }))
            offset += 4
            guard data.count >= offset + payloadSize else { return DoubaoProtocolError.invalidPayload }
            var payload = Data(data[data.startIndex + offset ..< data.startIndex + offset + payloadSize])
            if header.compression == .gzip {
                payload = try gzipDecompress(payload)
            }
            guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                return DoubaoProtocolError.invalidPayload
            }
            return DoubaoProtocolError.serverError(
                code: json["code"] as? Int,
                message: json["message"] as? String,
            )
        } catch {
            return error
        }
    }

    private static func buildContextString(hotwords: [String]) -> String? {
        let normalized = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }

        let context: [String: Any] = [
            "hotwords": normalized.map { ["word": $0, "scale": 5.0] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func gzipDecompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let pageSize = 16384
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
        defer { destination.deallocate() }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        var output = Data()
        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw DoubaoProtocolError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPointer) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw DoubaoProtocolError.decompressionFailed
            }

            streamPointer.pointee.src_ptr = baseAddress
            streamPointer.pointee.src_size = data.count
            streamPointer.pointee.dst_ptr = destination
            streamPointer.pointee.dst_size = pageSize

            repeat {
                status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = pageSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                }
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = pageSize
            } while status == COMPRESSION_STATUS_OK

            guard status == COMPRESSION_STATUS_END else {
                throw DoubaoProtocolError.decompressionFailed
            }

            return output
        }
    }
}
