import AVFoundation
import Foundation

struct OpenAIRealtimePreviewSupport {
    static func isSupported(baseURL: String, model: String) -> Bool {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized != "whisper-1"
    }

    static func webSocketURL(baseURL: String, model: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            return nil
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([trimmedPath, "realtime"].filter { !$0.isEmpty }).joined(separator: "/")
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "model" }
        queryItems.append(URLQueryItem(name: "model", value: model))
        components.queryItems = queryItems
        return components.url
    }
}

struct OpenAIRealtimeTranscriptAccumulator {
    private(set) var orderedItemIDs: [String] = []
    private(set) var partialTexts: [String: String] = [:]
    private(set) var finalTexts: [String: String] = [:]

    mutating func process(eventData: Data) throws -> TranscriptionSnapshot? {
        guard let payload = try JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        switch type {
        case "input_audio_buffer.committed":
            guard let itemID = payload["item_id"] as? String else { return nil }
            insert(itemID: itemID, after: payload["previous_item_id"] as? String)
            return snapshot(isFinal: false)

        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = payload["item_id"] as? String else { return nil }
            insert(itemID: itemID, after: payload["previous_item_id"] as? String)
            let delta = payload["delta"] as? String ?? ""
            partialTexts[itemID] = merge(existing: partialTexts[itemID] ?? finalTexts[itemID] ?? "", incoming: delta)
            return snapshot(isFinal: false)

        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = payload["item_id"] as? String else { return nil }
            insert(itemID: itemID, after: payload["previous_item_id"] as? String)
            let transcript = (payload["transcript"] as? String ?? partialTexts[itemID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            partialTexts[itemID] = transcript
            finalTexts[itemID] = transcript
            return snapshot(isFinal: false)

        default:
            return nil
        }
    }

    func finalText() -> String {
        composedText().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func composedText() -> String {
        orderedItemIDs
            .compactMap { finalTexts[$0] ?? partialTexts[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func snapshot(isFinal: Bool) -> TranscriptionSnapshot? {
        let text = composedText()
        guard !text.isEmpty else { return nil }
        return TranscriptionSnapshot(text: text, isFinal: isFinal)
    }

    private mutating func insert(itemID: String, after previousItemID: String?) {
        guard !orderedItemIDs.contains(itemID) else { return }
        if let previousItemID, let index = orderedItemIDs.firstIndex(of: previousItemID) {
            orderedItemIDs.insert(itemID, at: index + 1)
        } else {
            orderedItemIDs.append(itemID)
        }
    }

    private func merge(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return incoming }
        if incoming.hasPrefix(existing) { return incoming }
        if existing.hasPrefix(incoming) { return existing }
        return existing + incoming
    }
}

actor OpenAIRealtimePreviewBackend: LivePreviewBackend {
    private let settingsStore: SettingsStore
    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var onTextUpdate: (@Sendable (String) -> Void)?
    private var latestText = ""
    private var accumulator = OpenAIRealtimeTranscriptAccumulator()
    private let encoder = OpenAIRealtimeAudioEncoder()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    static func isSupported(settingsStore: SettingsStore) -> Bool {
        OpenAIRealtimePreviewSupport.isSupported(
            baseURL: settingsStore.whisperBaseURL,
            model: OpenAIAudioModelCatalog.normalizeWhisperModel(settingsStore.whisperModel)
        )
    }

    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws {
        cancel()

        let model = OpenAIAudioModelCatalog.normalizeWhisperModel(settingsStore.whisperModel)
        guard let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: settingsStore.whisperBaseURL,
            model: model
        ) else {
            throw NSError(
                domain: "OpenAIRealtimePreviewBackend",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid realtime WebSocket URL."]
            )
        }

        var request = URLRequest(url: url)
        if !settingsStore.whisperAPIKey.isEmpty {
            request.setValue("Bearer \(settingsStore.whisperAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let delegate = WebSocketOpenDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socketTask = session.webSocketTask(with: request)
        socketTask.resume()
        try await delegate.waitUntilOpen(timeout: .seconds(5))

        self.session = session
        self.socketTask = socketTask
        self.onTextUpdate = onTextUpdate
        self.latestText = ""
        self.accumulator = OpenAIRealtimeTranscriptAccumulator()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        let payload = buildSessionUpdatePayload()
        try await send(payload)
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        guard socketTask != nil else { return }
        do {
            let audioData = try encoder.encode(buffer: buffer)
            guard !audioData.isEmpty else { return }
            let payload: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": audioData.base64EncodedString()
            ]
            try await send(payload)
        } catch {
            NetworkDebugLogger.logError(context: "Realtime preview audio append failed", error: error)
        }
    }

    func finish() async -> String {
        do {
            try await send(["type": "input_audio_buffer.commit"])
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            NetworkDebugLogger.logError(context: "Realtime preview finish failed", error: error)
        }
        cancel()
        return latestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil
        onTextUpdate = nil
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let socketTask else { break }
                let message = try await socketTask.receive()
                guard let data = messageData(from: message) else { continue }
                if let snapshot = try accumulator.process(eventData: data) {
                    latestText = snapshot.text
                    onTextUpdate?(snapshot.text)
                }
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "Realtime preview receive failed", error: error)
                }
                break
            }
        }
    }

    private func buildSessionUpdatePayload() -> [String: Any] {
        let model = OpenAIAudioModelCatalog.normalizeWhisperModel(settingsStore.whisperModel)
        let prompt = TranscriptionLanguageHints.remotePrompt(vocabularyTerms: VocabularyStore.activeTerms())

        var transcriptionPayload: [String: Any] = [
            "model": model
        ]
        if let prompt {
            transcriptionPayload["prompt"] = prompt
        }

        let transcriptionSession: [String: Any] = [
            "type": "realtime.transcription_session",
            "input_audio_format": "pcm16",
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": 500,
                "prefix_padding_ms": 300
            ],
            "input_audio_transcription": transcriptionPayload
        ]

        return [
            "type": "session.update",
            "session": transcriptionSession
        ]
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let socketTask else { return }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "OpenAIRealtimePreviewBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode realtime payload."]
            )
        }
        try await socketTask.send(.string(text))
    }

    private func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }
}

private actor WebSocketOpenDelegateState {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilOpen(timeout: Duration) async throws {
        if opened { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await self.store(continuation: continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: "OpenAIRealtimePreviewBackend",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Realtime preview handshake timed out."]
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

private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let state = WebSocketOpenDelegateState()

    func waitUntilOpen(timeout: Duration) async throws {
        try await state.waitUntilOpen(timeout: timeout)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await state.markOpened() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { await state.markFailed(error) }
    }
}

private final class OpenAIRealtimeAudioEncoder {
    func encode(buffer: AVAudioPCMBuffer) throws -> Data {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "OpenAIRealtimeAudioEncoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime output format."]
            )
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            throw NSError(
                domain: "OpenAIRealtimeAudioEncoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime audio converter."]
            )
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw NSError(
                domain: "OpenAIRealtimeAudioEncoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate realtime audio buffer."]
            )
        }

        var error: NSError?
        var hasProvidedInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }
        guard status != .error else {
            throw NSError(
                domain: "OpenAIRealtimeAudioEncoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Realtime audio conversion failed."]
            )
        }

        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard let channelData = outputBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }
}
