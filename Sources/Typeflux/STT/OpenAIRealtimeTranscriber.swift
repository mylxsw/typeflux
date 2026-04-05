import AVFoundation
import Foundation

/// Transcribes a pre-recorded audio file using the OpenAI Realtime API via WebSocket.
/// Used as an optimization when the Whisper API endpoint points to OpenAI and the model
/// supports the realtime protocol (i.e. not whisper-1).
enum OpenAIRealtimeTranscriber {
    static func isOpenAIEndpoint(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.host?.lowercased() == "api.openai.com"
    }

    static func shouldUseRealtime(baseURL: String, model: String) -> Bool {
        guard ExperimentalFeatureFlags.openAIRealtimeSTTEnabled else { return false }
        guard isOpenAIEndpoint(baseURL) else { return false }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized != "whisper-1"
    }

    static func transcribe(
        audioFile: AudioFile,
        baseURL: String,
        apiKey: String,
        model: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let pcmData = try convertToPCM16(url: audioFile.fileURL)

        guard let wsURL = OpenAIRealtimePreviewSupport.webSocketURL(baseURL: baseURL, model: model) else {
            throw makeError(code: 1, message: "Failed to construct realtime WebSocket URL.")
        }

        NetworkDebugLogger.logMessage(
            "OpenAI Realtime ASR: connecting to \(wsURL.absoluteString)",
        )

        var request = URLRequest(url: wsURL)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let delegate = RealtimeTranscriberWSDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socketTask = session.webSocketTask(with: request)
        socketTask.resume()

        do {
            try await delegate.waitUntilOpen(timeout: .seconds(10))
        } catch {
            socketTask.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            throw error
        }

        defer {
            socketTask.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        // Configure transcription session without turn detection (manual commit only)
        let prompt = TranscriptionLanguageHints.remotePrompt(
            vocabularyTerms: VocabularyStore.activeTerms(),
        )
        try await sendSessionUpdate(socketTask: socketTask, model: model, prompt: prompt)

        // Send audio in chunks (~0.5s each at 24kHz mono 16-bit)
        let chunkBytes = 24000
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkBytes, pcmData.count)
            let chunk = pcmData.subdata(in: offset ..< end)
            try await sendPayload(socketTask: socketTask, payload: [
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ])
            offset = end
        }

        NetworkDebugLogger.logMessage(
            "OpenAI Realtime ASR: sent \(pcmData.count) bytes of PCM16 audio, committing buffer",
        )

        try await sendPayload(socketTask: socketTask, payload: ["type": "input_audio_buffer.commit"])

        // Wait for transcription with timeout
        return try await receiveTranscription(
            socketTask: socketTask,
            timeout: max(30, audioFile.duration * 3),
            onUpdate: onUpdate,
        )
    }

    // MARK: - Audio conversion

    private static let targetSampleRate: Double = 24000

    private static func convertToPCM16(url: URL) throws -> Data {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let totalSourceFrames = AVAudioFrameCount(sourceFile.length)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true,
        ) else {
            throw makeError(code: 10, message: "Failed to create target audio format.")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw makeError(code: 11, message: "Failed to create audio converter.")
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: totalSourceFrames,
        ) else {
            throw makeError(code: 12, message: "Failed to allocate source audio buffer.")
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: targetCapacity,
        ) else {
            throw makeError(code: 13, message: "Failed to allocate target audio buffer.")
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
            throw makeError(code: 14, message: "Audio conversion failed.")
        }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(targetBuffer.frameLength) * bytesPerFrame
        guard let channelData = targetBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }

    // MARK: - WebSocket messaging

    private static func sendSessionUpdate(
        socketTask: URLSessionWebSocketTask,
        model: String,
        prompt: String?,
    ) async throws {
        var transcriptionPayload: [String: Any] = [
            "model": model,
        ]
        if let prompt { transcriptionPayload["prompt"] = prompt }

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000,
                        ],
                        "transcription": transcriptionPayload,
                        "turn_detection": NSNull(),
                    ],
                ],
            ] as [String: Any],
        ]
        try await sendPayload(socketTask: socketTask, payload: payload)
    }

    private static func receiveTranscription(
        socketTask: URLSessionWebSocketTask,
        timeout: TimeInterval,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var accumulator = OpenAIRealtimeTranscriptAccumulator()
                while true {
                    let message = try await socketTask.receive()
                    guard let data = extractData(from: message) else { continue }

                    if let errorMessage = parseError(from: data) {
                        throw makeError(code: 4, message: "Realtime API error: \(errorMessage)")
                    }

                    if let snapshot = try accumulator.process(eventData: data) {
                        await onUpdate(snapshot)
                    }

                    if !accumulator.finalTexts.isEmpty {
                        let finalText = accumulator.finalText()
                        await onUpdate(TranscriptionSnapshot(text: finalText, isFinal: true))
                        NetworkDebugLogger.logMessage(
                            "OpenAI Realtime ASR: transcription complete: "
                                + (finalText.isEmpty ? "<empty>" : finalText),
                        )
                        return finalText
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw makeError(code: 2, message: "Realtime transcription timed out.")
            }

            guard let result = try await group.next() else {
                throw makeError(code: 2, message: "Realtime transcription timed out.")
            }
            group.cancelAll()
            return result
        }
    }

    private static func sendPayload(
        socketTask: URLSessionWebSocketTask,
        payload: [String: Any],
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw makeError(code: 3, message: "Failed to encode realtime payload.")
        }
        try await sendWithRetry(socketTask: socketTask, message: .string(text))
    }

    private static func extractData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data): return data
        case let .string(text): return text.data(using: .utf8)
        @unknown default: return nil
        }
    }

    private static func parseError(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String,
              type == "error"
        else { return nil }
        if let error = payload["error"] as? [String: Any] {
            return error["message"] as? String ?? "Unknown error"
        }
        return nil
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(
            domain: "OpenAIRealtimeTranscriber",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message],
        )
    }

    private static func sendWithRetry(
        socketTask: URLSessionWebSocketTask,
        message: URLSessionWebSocketTask.Message,
    ) async throws {
        let retryDelays: [Duration] = [.zero, .milliseconds(120), .milliseconds(300)]

        for (attempt, delay) in retryDelays.enumerated() {
            if attempt > 0 {
                try await Task.sleep(for: delay)
            }

            do {
                try await socketTask.send(message)
                return
            } catch {
                guard isRetriableSocketConnectionError(error), attempt < retryDelays.count - 1 else {
                    throw error
                }

                NetworkDebugLogger.logError(
                    context: "OpenAI Realtime ASR send failed before socket was ready; retrying",
                    error: error,
                )
            }
        }
    }

    private static func isRetriableSocketConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOTCONN) {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("socket is not connected") || message.contains("not connected")
    }
}

private actor RealtimeTranscriberWSDelegateState {
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
                    domain: "OpenAIRealtimeTranscriber",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "WebSocket connection timed out."],
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

    func markClosed(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let description = Self.describeClose(code: code, reason: reason)
        let error = NSError(
            domain: "OpenAIRealtimeTranscriber",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: description],
        )
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func store(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    private static func describeClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) -> String {
        let reasonText = reason
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let reasonText, !reasonText.isEmpty {
            return "WebSocket closed by server with code \(code.rawValue): \(reasonText)"
        }
        return "WebSocket closed by server with code \(code.rawValue)."
    }
}

private final class RealtimeTranscriberWSDelegate: NSObject, URLSessionWebSocketDelegate,
    URLSessionTaskDelegate
{
    private let state = RealtimeTranscriberWSDelegateState()

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

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?,
    ) {
        let reasonText = reason
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = if let reasonText, !reasonText.isEmpty {
            " reason=\(reasonText)"
        } else {
            ""
        }
        NetworkDebugLogger.logMessage(
            "OpenAI Realtime ASR: WebSocket closed with code=\(closeCode.rawValue)\(suffix)",
        )
        Task { await state.markClosed(code: closeCode, reason: reason) }
    }
}
