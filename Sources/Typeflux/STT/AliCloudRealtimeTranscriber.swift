import AVFoundation
import Foundation

// MARK: - Main Transcriber

final class AliCloudRealtimeTranscriber: Transcriber {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    static func testConnection(apiKey: String, model: String = AliCloudASRDefaults.model) async throws -> String {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw NSError(
                domain: "AliCloudRealtimeTranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Alibaba Cloud API key is not configured."],
            )
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AliCloudASRDefaults.model
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        let pcmData = RemoteSTTTestAudio.pcm16MonoSilence()

        if resolvedModel.lowercased().hasPrefix("qwen") {
            return try await AliCloudQwenASRSession.run(pcmData: pcmData, model: resolvedModel, apiKey: trimmedAPIKey) { _ in }
        } else {
            return try await AliCloudFunASRSession.run(pcmData: pcmData, model: resolvedModel, apiKey: trimmedAPIKey) { _ in }
        }
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let model = settingsStore.aliCloudModel
        let apiKey = settingsStore.aliCloudAPIKey

        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "AliCloudRealtimeTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Alibaba Cloud API key is not configured."],
            )
        }

        let pcmData = try AliCloudAudioConverter.convert(url: audioFile.fileURL)

        if model.lowercased().hasPrefix("qwen") {
            return try await AliCloudQwenASRSession.run(
                pcmData: pcmData, model: model, apiKey: apiKey, onUpdate: onUpdate,
            )
        } else {
            return try await AliCloudFunASRSession.run(
                pcmData: pcmData, model: model, apiKey: apiKey, onUpdate: onUpdate,
            )
        }
    }
}

// MARK: - Audio Converter

private enum AliCloudAudioConverter {
    static let targetSampleRate: Double = 16000
    /// 100ms of PCM16 at 16kHz mono: 16000 * 0.1 * 2 bytes = 3200
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
                domain: "AliCloudAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."],
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "AliCloudAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."],
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "AliCloudAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."],
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "AliCloudAudioConverter",
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
                domain: "AliCloudAudioConverter",
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

// MARK: - FunASR Session (DashScope WebSocket protocol)

private actor AliCloudFunASRSession {
    static func run(
        pcmData: Data,
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let session = AliCloudFunASRSession(pcmData: pcmData, model: model, apiKey: apiKey, onUpdate: onUpdate)
        return try await session.execute()
    }

    private let pcmData: Data
    private let model: String
    private let apiKey: String
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void

    // Confirmed segments are finalized sentences (sentence_end=true).
    // partialText is the current in-progress sentence being streamed.
    // This prevents redundant/repeated text when partial updates arrive with
    // different begin_time values for the same in-progress sentence.
    private var confirmedSegments: [String] = []
    private var partialText: String = ""
    private var lastEmitted: String = ""

    private var taskStarted = false
    private var taskFinished = false
    private var taskError: Error?
    private var taskStartedCont: CheckedContinuation<Void, Error>?
    private var taskFinishedCont: CheckedContinuation<Void, Error>?

    private init(
        pcmData: Data,
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) {
        self.pcmData = pcmData
        self.model = model
        self.apiKey = apiKey
        self.onUpdate = onUpdate
    }

    private func execute() async throws -> String {
        let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!
        var request = URLRequest(url: url)
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        NetworkDebugLogger.logRequest(request, bodyDescription: "<websocket handshake>")
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "connect", details: "model=\(model)")

        let socketDelegate = AliCloudWSDelegate()
        let urlSession = URLSession(configuration: .default, delegate: socketDelegate, delegateQueue: nil)
        let socketTask = urlSession.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .normalClosure, reason: nil)
            urlSession.invalidateAndCancel()
        }

        try await socketDelegate.waitUntilOpen(timeout: .seconds(10))
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "open")

        let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let runTask: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                    "semantic_punctuation_enabled": false,
                    "max_sentence_silence": 800,
                    "heartbeat": false,
                ],
                "input": [String: Any](),
            ],
        ]
        try await sendJSON(runTask, to: socketTask)

        let receiveTask = Task { [weak self] in
            await self?.receiveLoop(socketTask: socketTask)
        }
        defer { receiveTask.cancel() }

        try await waitForTaskStarted()

        // Stream audio in chunks
        var offset = 0
        let chunkSize = AliCloudAudioConverter.chunkSize
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData[offset ..< end]
            try await socketTask.send(.data(chunk))
            offset = end
        }

        let finishTask: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": ["input": [String: Any]()],
        ]
        try await sendJSON(finishTask, to: socketTask)

        try await waitForTaskFinished()

        return composedText()
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                let data: Data? = switch message {
                case let .data(d): d
                case let .string(s): s.data(using: .utf8)
                @unknown default: nil
                }
                guard let data else { continue }
                NetworkDebugLogger.logWebSocketEvent(
                    provider: "AliCloud FunASR",
                    phase: "receive",
                    details: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>",
                )
                handleEvent(data: data)
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "AliCloud FunASR receive loop failed", error: error)
                    signalError(error)
                }
                break
            }
        }
    }

    private func handleEvent(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "task-started")
            taskStarted = true
            taskStartedCont?.resume()
            taskStartedCont = nil

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  let text = sentence["text"] as? String else { return }

            // Heartbeat events carry empty text; skip them.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let isFinal = sentence["sentence_end"] as? Bool ?? false

            if isFinal {
                // Move this finalized sentence into confirmed segments and clear the partial.
                let normalized = AliCloudTextNormalizer.normalize(segment: trimmed, after: confirmedSegments.joined())
                confirmedSegments.append(normalized)
                partialText = ""
            } else {
                // Replace (not append) the partial — only the latest interim result matters.
                partialText = AliCloudTextNormalizer.normalize(segment: trimmed, after: confirmedSegments.joined())
            }

            let preview = composedText()
            guard preview != lastEmitted else { return }
            lastEmitted = preview
            Task { [weak self] in
                guard let self else { return }
                await onUpdate(TranscriptionSnapshot(text: preview, isFinal: false))
            }

        case "task-finished":
            NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "task-finished")
            taskFinished = true
            taskFinishedCont?.resume()
            taskFinishedCont = nil

        case "task-failed":
            let msg = (header["message"] as? String) ?? "ASR task failed"
            let code = (header["status"] as? Int) ?? -1
            NetworkDebugLogger.logWebSocketEvent(
                provider: "AliCloud FunASR",
                phase: "task-failed",
                details: "code=\(code) message=\(msg)",
            )
            signalError(NSError(
                domain: "AliCloudFunASR",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: msg],
            ))

        default:
            break
        }
    }

    private func composedText() -> String {
        var pieces = confirmedSegments
        if !partialText.isEmpty {
            pieces.append(partialText)
        }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func signalError(_ error: Error) {
        taskError = error
        taskStartedCont?.resume(throwing: error)
        taskStartedCont = nil
        taskFinishedCont?.resume(throwing: error)
        taskFinishedCont = nil
    }

    private func waitForTaskStarted() async throws {
        if taskStarted { return }
        if let error = taskError { throw error }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            taskStartedCont = cont
        }
    }

    private func waitForTaskFinished() async throws {
        if taskFinished { return }
        if let error = taskError { throw error }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            taskFinishedCont = cont
        }
    }

    private func sendJSON(_ json: [String: Any], to socketTask: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "AliCloudFunASR",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON payload."],
            )
        }
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "send", details: text)
        try await socketTask.send(.string(text))
    }
}

// MARK: - Text Normalizer

enum AliCloudTextNormalizer {
    /// Joins a new segment to existing text with smart spacing:
    /// no space between CJK characters, space between latin words.
    static func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty else { return "" }
        guard let lastChar = existingText.last else { return segment }
        guard let firstChar = segment.first else { return segment }

        // No extra space needed when adjacent to whitespace or punctuation boundaries
        if lastChar.isWhitespace || firstChar.isWhitespace { return segment }
        if firstChar.isAliCloudClosingPunctuation || lastChar.isAliCloudOpeningPunctuation { return segment }

        // No space between CJK ideographs (Chinese/Japanese/Korean)
        if lastChar.isAliCloudCJKIdeograph || firstChar.isAliCloudCJKIdeograph { return segment }

        // Default: separate with a space (e.g. English words)
        return " " + segment
    }
}

extension Character {
    var isAliCloudClosingPunctuation: Bool {
        ",.!?;:)]}\"'".contains(self)
    }

    var isAliCloudOpeningPunctuation: Bool {
        "([{/\"'".contains(self)
    }

    var isAliCloudCJKIdeograph: Bool {
        unicodeScalars.contains {
            switch $0.value {
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF: true
            default: false
            }
        }
    }
}

// MARK: - Qwen ASR Session (OpenAI Realtime-compatible protocol)

private actor AliCloudQwenASRSession {
    static func run(
        pcmData: Data,
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let session = AliCloudQwenASRSession(pcmData: pcmData, model: model, apiKey: apiKey, onUpdate: onUpdate)
        return try await session.execute()
    }

    private let pcmData: Data
    private let model: String
    private let apiKey: String
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private var accumulator = OpenAIRealtimeTranscriptAccumulator()

    private var sessionReady = false
    private var sessionFinished = false
    private var sessionError: Error?
    private var sessionReadyCont: CheckedContinuation<Void, Error>?
    private var sessionFinishedCont: CheckedContinuation<Void, Error>?

    private init(
        pcmData: Data,
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) {
        self.pcmData = pcmData
        self.model = model
        self.apiKey = apiKey
        self.onUpdate = onUpdate
    }

    private func execute() async throws -> String {
        let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        NetworkDebugLogger.logRequest(request, bodyDescription: "<websocket handshake>")
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud Qwen ASR", phase: "connect", details: "model=\(model)")

        let socketDelegate = AliCloudWSDelegate()
        let urlSession = URLSession(configuration: .default, delegate: socketDelegate, delegateQueue: nil)
        let socketTask = urlSession.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .normalClosure, reason: nil)
            urlSession.invalidateAndCancel()
        }

        try await socketDelegate.waitUntilOpen(timeout: .seconds(10))
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud Qwen ASR", phase: "open")

        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": 16000,
                "turn_detection": NSNull(),
            ],
        ]
        try await sendJSON(sessionUpdate, to: socketTask)

        let receiveTask = Task { [weak self] in
            await self?.receiveLoop(socketTask: socketTask)
        }
        defer { receiveTask.cancel() }

        try await waitForSessionReady()

        // Stream audio in base64-encoded chunks
        var offset = 0
        let chunkSize = AliCloudAudioConverter.chunkSize
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData[offset ..< end]
            let audioAppend: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ]
            try await sendJSON(audioAppend, to: socketTask)
            offset = end
        }

        try await sendJSON(["type": "input_audio_buffer.commit"], to: socketTask)
        try await sendJSON(["type": "session.finish"], to: socketTask)

        try await waitForSessionFinished()

        return accumulator.finalText()
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                let data: Data? = switch message {
                case let .data(d): d
                case let .string(s): s.data(using: .utf8)
                @unknown default: nil
                }
                guard let data else { continue }
                NetworkDebugLogger.logWebSocketEvent(
                    provider: "AliCloud Qwen ASR",
                    phase: "receive",
                    details: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>",
                )
                handleEvent(data: data)
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "AliCloud Qwen ASR receive loop failed", error: error)
                    signalError(error)
                }
                break
            }
        }
    }

    private func handleEvent(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "session.updated":
            NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud Qwen ASR", phase: type)
            sessionReady = true
            sessionReadyCont?.resume()
            sessionReadyCont = nil

        case "session.finished":
            NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud Qwen ASR", phase: "session.finished")
            sessionFinished = true
            sessionFinishedCont?.resume()
            sessionFinishedCont = nil

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Session error"
            NetworkDebugLogger.logWebSocketEvent(
                provider: "AliCloud Qwen ASR",
                phase: "error",
                details: message,
            )
            signalError(NSError(
                domain: "AliCloudQwenASR",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message],
            ))

        default:
            if let snapshot = try? accumulator.process(eventData: data) {
                Task { [weak self] in
                    guard let self else { return }
                    await onUpdate(snapshot)
                }
            }
        }
    }

    private func signalError(_ error: Error) {
        sessionError = error
        sessionReadyCont?.resume(throwing: error)
        sessionReadyCont = nil
        sessionFinishedCont?.resume(throwing: error)
        sessionFinishedCont = nil
    }

    private func waitForSessionReady() async throws {
        if sessionReady { return }
        if let error = sessionError { throw error }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionReadyCont = cont
        }
    }

    private func waitForSessionFinished() async throws {
        if sessionFinished { return }
        if let error = sessionError { throw error }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionFinishedCont = cont
        }
    }

    private func sendJSON(_ json: [String: Any], to socketTask: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "AliCloudQwenASR",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON payload."],
            )
        }
        NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud Qwen ASR", phase: "send", details: text)
        try await socketTask.send(.string(text))
    }
}

// MARK: - WebSocket Delegate

private actor AliCloudWSDelegateState {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilOpen(timeout: Duration) async throws {
        if opened { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.store(continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: "AliCloudWSDelegate",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WebSocket handshake timed out."],
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func markOpened() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    func markFailed(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func store(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
}

private final class AliCloudWSDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let state = AliCloudWSDelegateState()

    func waitUntilOpen(timeout: Duration) async throws {
        try await state.waitUntilOpen(timeout: timeout)
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?,
    ) {
        Task { await state.markOpened() }
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
