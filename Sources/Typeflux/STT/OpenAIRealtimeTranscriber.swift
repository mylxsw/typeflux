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
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let pcmData = try convertToPCM16(url: audioFile.fileURL)

        guard let wsURL = OpenAIRealtimePreviewSupport.webSocketURL(baseURL: baseURL, model: model) else {
            throw makeError(code: 1, message: "Failed to construct realtime WebSocket URL.")
        }

        NetworkDebugLogger.logMessage(
            "OpenAI Realtime ASR: connecting to \(wsURL.absoluteString)"
        )

        var request = URLRequest(url: wsURL)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let socket = OpenAIRealtimeSocket(request: request, logPrefix: "OpenAI Realtime ASR")
        try await socket.connect(timeout: .seconds(10))

        defer {
            socket.disconnect()
        }

        // Configure transcription session without turn detection (manual commit only)
        let prompt = TranscriptionLanguageHints.remotePrompt(
            vocabularyTerms: VocabularyStore.activeTerms()
        )
        try await sendSessionUpdate(socket: socket, model: model, prompt: prompt)

        // Send audio in chunks (~0.5s each at 24kHz mono 16-bit)
        let chunkBytes = 24_000
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkBytes, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await sendPayload(socket: socket, payload: [
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ])
            offset = end
        }

        NetworkDebugLogger.logMessage(
            "OpenAI Realtime ASR: sent \(pcmData.count) bytes of PCM16 audio, committing buffer"
        )

        try await sendPayload(socket: socket, payload: ["type": "input_audio_buffer.commit"])

        // Wait for transcription with timeout
        return try await receiveTranscription(
            socket: socket,
            timeout: max(30, audioFile.duration * 3),
            onUpdate: onUpdate
        )
    }

    // MARK: - Audio conversion

    private static let targetSampleRate: Double = 24_000

    private static func convertToPCM16(url: URL) throws -> Data {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let totalSourceFrames = AVAudioFrameCount(sourceFile.length)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw makeError(code: 10, message: "Failed to create target audio format.")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw makeError(code: 11, message: "Failed to create audio converter.")
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: totalSourceFrames
        ) else {
            throw makeError(code: 12, message: "Failed to allocate source audio buffer.")
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: targetCapacity
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
        socket: OpenAIRealtimeSocket,
        model: String,
        prompt: String?
    ) async throws {
        var transcriptionPayload: [String: Any] = [
            "model": model
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
                            "rate": 24_000
                        ],
                        "transcription": transcriptionPayload,
                        "turn_detection": NSNull()
                    ]
                ]
            ] as [String: Any],
        ]
        try await sendPayload(socket: socket, payload: payload)
    }

    private static func receiveTranscription(
        socket: OpenAIRealtimeSocket,
        timeout: TimeInterval,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var accumulator = OpenAIRealtimeTranscriptAccumulator()
                for try await data in socket.messages {
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
                                + (finalText.isEmpty ? "<empty>" : finalText)
                        )
                        return finalText
                    }
                }
                throw makeError(code: 7, message: "Realtime connection closed before transcription completed.")
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
        socket: OpenAIRealtimeSocket,
        payload: [String: Any]
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw makeError(code: 3, message: "Failed to encode realtime payload.")
        }
        try await socket.send(text: text)
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
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
