import AVFoundation
import Foundation
import os

// MARK: - LLM Integration Types

/// Configuration for server-side LLM rewrite, sent as part of the ASR start message.
/// When included, the server runs an LLM pass after transcription and streams the
/// result back over the same WebSocket connection.
struct ASRLLMConfig: Encodable {
    /// Fully-assembled system prompt (language policy + persona + environment context).
    let systemPrompt: String
    /// User prompt template containing "{{transcript}}" as a placeholder for the
    /// final transcription text. The server substitutes it before calling the LLM.
    let userPromptTemplate: String

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case userPromptTemplate = "user_prompt_template"
    }
}

/// Transcribers that support a merged ASR + LLM rewrite in a single WebSocket session.
protocol TypefluxCloudLLMIntegratedTranscriber: TypefluxCloudScenarioAwareTranscriber {
    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void,
    ) async throws -> (transcript: String, rewritten: String?)
}

// MARK: - Main Transcriber

final class TypefluxOfficialTranscriber: TypefluxCloudScenarioAwareTranscriber, TypefluxCloudLLMIntegratedTranscriber {
    private let logger = Logger(subsystem: "dev.typeflux", category: "TypefluxOfficialTranscriber")

    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let token = await MainActor.run { AuthState.shared.accessToken }
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = try TypefluxOfficialAudioConverter.convert(url: audioFile.fileURL)
        return try await TypefluxOfficialASRSession.run(
            pcmData: pcmData,
            token: token,
            scenario: scenario,
            onUpdate: onUpdate,
        )
    }

    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void,
    ) async throws -> (transcript: String, rewritten: String?) {
        let token = await MainActor.run { AuthState.shared.accessToken }
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = try TypefluxOfficialAudioConverter.convert(url: audioFile.fileURL)
        return try await TypefluxOfficialASRSession.runWithLLM(
            pcmData: pcmData,
            token: token,
            scenario: scenario,
            llmConfig: llmConfig,
            onASRUpdate: onASRUpdate,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk,
        )
    }

    static func testConnection() async throws -> String {
        let token = await MainActor.run { AuthState.shared.accessToken }
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = RemoteSTTTestAudio.pcm16MonoSilence()
        return try await TypefluxOfficialASRSession.run(
            pcmData: pcmData,
            token: token,
            scenario: .modelSetup,
        ) { _ in }
    }
}

// MARK: - Errors

enum TypefluxOfficialASRError: LocalizedError {
    case notLoggedIn
    case connectionFailed(String)
    case serverError(String)
    case unexpectedClose

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Please sign in to use Typeflux Cloud speech recognition."
        case .connectionFailed(let reason):
            "Failed to connect to Typeflux ASR service: \(reason)"
        case .serverError(let message):
            "Typeflux ASR error: \(message)"
        case .unexpectedClose:
            "The Typeflux ASR connection closed unexpectedly."
        }
    }
}

enum TypefluxOfficialASRClosePolicy {
    static func shouldTreatReceiveFailureAsUnexpectedClose(
        completed: Bool,
        finalSegments: [String]
    ) -> Bool {
        !completed && finalSegments.isEmpty
    }
}

// MARK: - Audio Converter

private enum TypefluxOfficialAudioConverter {
    static let targetSampleRate: Double = 16000
    /// 100ms of PCM16 at 16kHz mono = 3200 bytes
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
                domain: "TypefluxOfficialAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."],
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "TypefluxOfficialAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."],
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "TypefluxOfficialAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."],
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "TypefluxOfficialAudioConverter",
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
                domain: "TypefluxOfficialAudioConverter",
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

enum TypefluxOfficialASRRequestFactory {
    static func makeWebSocketRequest(
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
    ) throws -> URLRequest {
        let wsScheme = apiBaseURL.hasPrefix("https") ? "wss" : "ws"
        let host = apiBaseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let urlString = "\(wsScheme)://\(host)/api/v1/asr/ws/default"

        guard let url = URL(string: urlString) else {
            throw TypefluxOfficialASRError.connectionFailed("Invalid WebSocket URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        TypefluxCloudRequestHeaders.applyScenario(scenario, to: &request)
        return request
    }
}

// MARK: - WebSocket ASR Session

private actor TypefluxOfficialASRSession {
    static func run(
        pcmData: Data,
        token: String,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            token: token,
            scenario: scenario,
            onASRUpdate: onUpdate,
            llmConfig: nil,
            onLLMStart: nil,
            onLLMChunk: nil,
        )
        let (transcript, _) = try await session.execute()
        return transcript
    }

    static func runWithLLM(
        pcmData: Data,
        token: String,
        scenario: TypefluxCloudScenario,
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void,
    ) async throws -> (transcript: String, rewritten: String?) {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            token: token,
            scenario: scenario,
            onASRUpdate: onASRUpdate,
            llmConfig: llmConfig,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk,
        )
        return try await session.execute()
    }

    private let pcmData: Data
    private let token: String
    private let scenario: TypefluxCloudScenario
    private let onASRUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let llmConfig: ASRLLMConfig?
    private let onLLMStart: (@Sendable () async -> Void)?
    private let onLLMChunk: (@Sendable (String) async -> Void)?
    private let logger = Logger(subsystem: "dev.typeflux", category: "TypefluxOfficialASRSession")

    private var finalSegments: [String] = []
    private var currentPartialText: String = ""
    private var completed = false
    private var sessionError: Error?
    private var rewrittenText: String?

    private init(
        pcmData: Data,
        token: String,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        llmConfig: ASRLLMConfig?,
        onLLMStart: (@Sendable () async -> Void)?,
        onLLMChunk: (@Sendable (String) async -> Void)?,
    ) {
        self.pcmData = pcmData
        self.token = token
        self.scenario = scenario
        self.onASRUpdate = onASRUpdate
        self.llmConfig = llmConfig
        self.onLLMStart = onLLMStart
        self.onLLMChunk = onLLMChunk
    }

    private func execute() async throws -> (transcript: String, rewritten: String?) {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: AppServerConfiguration.apiBaseURL,
            token: token,
            scenario: scenario,
        )
        let session = URLSession(configuration: .default)
        let socketTask = session.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .goingAway, reason: nil)
            session.finishTasksAndInvalidate()
        }

        // Build start message; include LLM config when present.
        let audioConfig: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "channel": 1,
            "lang": "auto",
        ]
        var config: [String: Any] = ["audio": audioConfig]
        if let llmConfig {
            config["llm"] = [
                "system_prompt": llmConfig.systemPrompt,
                "user_prompt_template": llmConfig.userPromptTemplate,
            ]
        }
        let startMessage: [String: Any] = ["type": "start", "config": config]
        let startData = try JSONSerialization.data(withJSONObject: startMessage)
        try await socketTask.send(.string(String(data: startData, encoding: .utf8)!))

        // Start receive loop in a separate task
        let receiveTask = Task { [self] in
            await self.receiveLoop(socketTask: socketTask)
        }

        // Stream audio chunks
        let chunkSize = TypefluxOfficialAudioConverter.chunkSize
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData[offset ..< end]
            try await socketTask.send(.data(Data(chunk)))
            offset = end
        }

        // Send stop message
        let stopMessage = try JSONSerialization.data(withJSONObject: ["type": "stop"])
        try await socketTask.send(.string(String(data: stopMessage, encoding: .utf8)!))

        // Wait for receive loop to complete
        await receiveTask.value

        if let error = sessionError {
            throw error
        }

        let transcript = assembleTranscript()
        if !transcript.isEmpty {
            await onASRUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        return (transcript: transcript, rewritten: rewrittenText)
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !completed {
            do {
                let message = try await socketTask.receive()
                switch message {
                case .string(let text):
                    await handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                    completed: completed,
                    finalSegments: finalSegments
                ) {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    sessionError = sessionError ?? TypefluxOfficialASRError.unexpectedClose
                }
                completed = true
            }
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "partial":
            let partialText = json["text"] as? String ?? ""
            currentPartialText = partialText
            let display = assembleTranscript()
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: false))

        case "final":
            let finalText = json["text"] as? String ?? ""
            if !finalText.isEmpty {
                finalSegments.append(finalText)
            }
            currentPartialText = ""
            let display = assembleTranscript()
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: false))

        case "event":
            let eventText = json["text"] as? String ?? ""
            if eventText == "completed" {
                // If LLM is pending, keep the receive loop alive to handle llm_* messages.
                if llmConfig == nil {
                    completed = true
                }
            }

        case "llm_start":
            await onLLMStart?()

        case "llm_chunk":
            let chunkText = json["text"] as? String ?? ""
            if !chunkText.isEmpty {
                await onLLMChunk?(chunkText)
            }

        case "llm_final":
            let finalRewrite = json["text"] as? String ?? ""
            rewrittenText = finalRewrite.isEmpty ? nil : finalRewrite
            completed = true

        case "error":
            let errorText = json["error"] as? String ?? "Unknown error"
            logger.error("ASR server error: \(errorText)")
            sessionError = TypefluxOfficialASRError.serverError(errorText)
            completed = true

        default:
            break
        }
    }

    private func assembleTranscript() -> String {
        var parts = finalSegments
        if !currentPartialText.isEmpty {
            parts.append(currentPartialText)
        }
        return parts.joined()
    }
}
