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
    /// 2000ms of silence appended before finish-task so the server can finalize
    /// the last sentence. The server's max_sentence_silence is 800ms, so 2000ms
    /// gives a generous margin for the server to emit sentence_end=true before
    /// finish-task is received: 16000 * 2.0 * 2 bytes = 64000
    static let trailingSilenceBytes: Int = 64000
    /// Timeout used after task-finished to wait for the last sentence to be finalized
    /// (sentence_end=true). The server sometimes emits the final result-generated
    /// slightly after task-finished when pre-recorded audio is processed faster than
    /// real-time. The event-driven drain wakes up immediately on sentence_end=true,
    /// so this timeout is only hit in the degenerate case where the server never
    /// sends it (e.g. very short utterance, VAD didn't fire).
    static let lastSentenceDrainTimeout: Duration = .seconds(3)

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
    private let snapshotDispatcher: AliCloudSnapshotDispatcher

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
    private let drainState = AliCloudFunASRDrainState()

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
        snapshotDispatcher = AliCloudSnapshotDispatcher(onUpdate: onUpdate)
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

        // Append trailing silence so the server has enough pause to finalize the last
        // sentence (max_sentence_silence = 800 ms). Without this, the final spoken
        // phrase may not receive a sentence_end=true event before task-finished arrives.
        let silencePadding = Data(count: AliCloudAudioConverter.trailingSilenceBytes)
        var silenceOffset = 0
        while silenceOffset < silencePadding.count {
            let end = min(silenceOffset + chunkSize, silencePadding.count)
            try await socketTask.send(.data(silencePadding[silenceOffset ..< end]))
            silenceOffset = end
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

        // Event-driven drain: if the last sentence is still pending (partialText
        // is not empty), wait for the server to emit sentence_end=true before
        // returning. The server sometimes sends this result-generated just after
        // task-finished because it finalizes the task while the ASR model is still
        // processing the last utterance. A fixed sleep is insufficient; this
        // approach wakes up immediately when the sentence is confirmed, and only
        // falls back to the timeout in the degenerate case (e.g. server VAD
        // never fires, very short or silent recording).
        await waitForLastSentenceOrTimeout(AliCloudAudioConverter.lastSentenceDrainTimeout)
        await snapshotDispatcher.flush()

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
                await handleEvent(data: data)
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "AliCloud FunASR receive loop failed", error: error)
                    signalError(error)
                }
                break
            }
        }
    }

    private func handleEvent(data: Data) async {
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
                // Wake up any post-task-finished drain that is waiting for this signal.
                resumeLastSentenceCont()
            } else {
                // Replace (not append) the partial — only the latest interim result matters.
                partialText = AliCloudTextNormalizer.normalize(segment: trimmed, after: confirmedSegments.joined())
            }

            let preview = composedText()
            guard preview != lastEmitted else { return }
            lastEmitted = preview
            await snapshotDispatcher.submit(TranscriptionSnapshot(text: preview, isFinal: false))

        case "task-finished":
            NetworkDebugLogger.logWebSocketEvent(provider: "AliCloud FunASR", phase: "task-finished")
            taskFinished = true
            taskFinishedCont?.resume()
            taskFinishedCont = nil

        case "task-failed":
            let msg = (header["error_message"] as? String) ?? "ASR task failed"
            let errorCode = (header["error_code"] as? String) ?? "UNKNOWN"
            NetworkDebugLogger.logWebSocketEvent(
                provider: "AliCloud FunASR",
                phase: "task-failed",
                details: "code=\(errorCode) message=\(msg)",
            )
            signalError(NSError(
                domain: "AliCloudFunASR",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "[\(errorCode)] \(msg)"],
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
        // Also wake up any active last-sentence drain so it exits immediately
        // rather than waiting for the full timeout after a connection error.
        resumeLastSentenceCont()
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

    /// Signals the drain to exit immediately (idempotent — safe to call multiple times).
    private func resumeLastSentenceCont() {
        Task { await drainState.signal() }
    }

    /// Waits until the last in-progress sentence is finalized (sentence_end=true)
    /// or the timeout elapses — whichever comes first.
    ///
    /// After receiving task-finished the server may still emit result-generated
    /// with sentence_end=true for the utterance it was processing when finish-task
    /// arrived. This method parks the actor until that signal arrives, then
    /// returns immediately. If the server never sends it (e.g. silence-only
    /// recording, VAD didn't fire) the timeout acts as a safety net and we
    /// return with whatever partialText we have.
    private func waitForLastSentenceOrTimeout(_ timeout: Duration) async {
        await drainState.waitForSentenceEndOrTimeout(hasPartial: !partialText.isEmpty, timeout: timeout)
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

// MARK: - Drain State (testable helper)

/// Encapsulates the "wait for sentence_end=true OR timeout" drain pattern used
/// by AliCloudFunASRSession after receiving task-finished.
///
/// Extracted as a standalone internal actor so the logic can be unit-tested
/// without a real WebSocket connection.
actor AliCloudFunASRDrainState {
    private var continuation: CheckedContinuation<Void, Never>?

    /// Resumes any waiting drain immediately (idempotent — safe to call multiple times).
    func signal() {
        continuation?.resume()
        continuation = nil
    }

    /// Parks the caller until `signal()` is called or `timeout` elapses.
    ///
    /// - Parameter hasPartial: Pass `partialText.isEmpty == false` from the session.
    ///   When `false` the call returns immediately (fast path).
    /// - Parameter timeout: Maximum time to wait before returning with whatever
    ///   partial text is currently available.
    func waitForSentenceEndOrTimeout(hasPartial: Bool, timeout: Duration) async {
        guard hasPartial else { return }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.signal()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
        }

        timeoutTask.cancel()
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
    private let snapshotDispatcher: AliCloudSnapshotDispatcher
    private var accumulator = OpenAIRealtimeTranscriptAccumulator()

    private var sessionReady = false
    private var sessionFinished = false
    private var sessionError: Error?
    private var sessionReadyCont: CheckedContinuation<Void, Error>?
    private var sessionFinishedCont: CheckedContinuation<Void, Error>?
    private let drainState = AliCloudFunASRDrainState()

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
        snapshotDispatcher = AliCloudSnapshotDispatcher(onUpdate: onUpdate)
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

        // Append trailing silence so the server can finalize the last sentence before
        // the session ends (mirrors the same fix in AliCloudFunASRSession).
        let silencePadding = Data(count: AliCloudAudioConverter.trailingSilenceBytes)
        var silenceOffset = 0
        while silenceOffset < silencePadding.count {
            let end = min(silenceOffset + chunkSize, silencePadding.count)
            let silenceAppend: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": silencePadding[silenceOffset ..< end].base64EncodedString(),
            ]
            try await sendJSON(silenceAppend, to: socketTask)
            silenceOffset = end
        }

        try await sendJSON(["type": "input_audio_buffer.commit"], to: socketTask)
        try await sendJSON(["type": "session.finish"], to: socketTask)

        try await waitForSessionFinished()

        // Event-driven drain: wait for all committed audio items to receive
        // conversation.item.input_audio_transcription.completed. The server can
        // send session.finished before the final transcription event arrives,
        // identical to the task-finished / result-generated race in FunASR.
        let hasPendingItems = !accumulator.orderedItemIDs.isEmpty &&
            !accumulator.orderedItemIDs.allSatisfy { accumulator.finalTexts[$0] != nil }
        await drainState.waitForSentenceEndOrTimeout(
            hasPartial: hasPendingItems,
            timeout: AliCloudAudioConverter.lastSentenceDrainTimeout,
        )
        await snapshotDispatcher.flush()

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
                await handleEvent(data: data)
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "AliCloud Qwen ASR receive loop failed", error: error)
                    signalError(error)
                }
                break
            }
        }
    }

    private func handleEvent(data: Data) async {
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
                await snapshotDispatcher.submit(snapshot)
            }
            // Signal the drain when every committed item has a finalTexts entry
            // (i.e. conversation.item.input_audio_transcription.completed received).
            // signal() is idempotent so calling it on every event is safe.
            if !accumulator.orderedItemIDs.isEmpty,
               accumulator.orderedItemIDs.allSatisfy({ accumulator.finalTexts[$0] != nil }) {
                await drainState.signal()
            }
        }
    }

    private func signalError(_ error: Error) {
        sessionError = error
        sessionReadyCont?.resume(throwing: error)
        sessionReadyCont = nil
        sessionFinishedCont?.resume(throwing: error)
        sessionFinishedCont = nil
        // Wake up any active drain immediately so it doesn't wait the full timeout.
        Task { await drainState.signal() }
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

private actor AliCloudSnapshotDispatcher {
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private var pendingSnapshot: TranscriptionSnapshot?
    private var isDispatching = false
    private var flushContinuations: [CheckedContinuation<Void, Never>] = []

    init(onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void) {
        self.onUpdate = onUpdate
    }

    func submit(_ snapshot: TranscriptionSnapshot) {
        pendingSnapshot = merge(existing: pendingSnapshot, incoming: snapshot)
        guard !isDispatching else { return }
        isDispatching = true
        Task { await drain() }
    }

    func flush() async {
        if !isDispatching, pendingSnapshot == nil { return }
        await withCheckedContinuation { continuation in
            flushContinuations.append(continuation)
        }
    }

    private func drain() async {
        while true {
            guard let snapshot = pendingSnapshot else {
                isDispatching = false
                let continuations = flushContinuations
                flushContinuations.removeAll()
                for continuation in continuations {
                    continuation.resume()
                }
                return
            }

            pendingSnapshot = nil
            await onUpdate(snapshot)
        }
    }

    private func merge(existing: TranscriptionSnapshot?, incoming: TranscriptionSnapshot) -> TranscriptionSnapshot {
        guard let existing else { return incoming }
        if incoming.isFinal || !existing.isFinal {
            return incoming
        }
        return existing
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
