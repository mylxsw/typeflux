import AppKit
import Foundation

/// Transcribes audio by sending it directly to an OpenAI-compatible multimodal LLM.
/// When a persona is active, the model transcribes AND applies persona rewriting in a single
/// API call — no separate LLM rewrite step is needed.
///
/// Audio is base64-encoded and sent as `input_audio` in the chat completions request.
/// Supports streaming via SSE for minimal time-to-first-token latency.
final class MultimodalLLMTranscriber: Transcriber {
    static let audioProcessingInstructionText = "This input_audio item contains the user's spoken audio. Please process it according to the system prompt and return only the requested final text."

    private let settingsStore: SettingsStore
    private let frontmostBundleIdentifierProvider: @Sendable () -> String?

    init(
        settingsStore: SettingsStore,
        frontmostBundleIdentifierProvider: @escaping @Sendable () -> String? = MultimodalLLMTranscriber.defaultFrontmostBundleIdentifierProvider,
    ) {
        self.settingsStore = settingsStore
        self.frontmostBundleIdentifierProvider = frontmostBundleIdentifierProvider
    }

    /// Default lookup for the focused app's bundle identifier. Excludes Typeflux
    /// itself so a stray main-thread dispatch ordering never reports the overlay
    /// as the frontmost app.
    static let defaultFrontmostBundleIdentifierProvider: @Sendable () -> String? = {
        let candidate = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let candidate, candidate != Bundle.main.bundleIdentifier else {
            return nil
        }
        return candidate
    }

    static func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            throw NSError(
                domain: "MultimodalLLMTranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Multimodal LLM base URL is not configured."],
            )
        }
        guard let resolvedBaseURL = URL(string: trimmedBaseURL) else {
            throw NSError(
                domain: "MultimodalLLMTranscriber",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Multimodal LLM base URL is invalid."],
            )
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? OpenAIAudioModelCatalog.multimodalModels[0]
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try makeTestRequest(baseURL: resolvedBaseURL, model: resolvedModel, apiKey: apiKey)

        var buffer = ""
        for try await chunk in try await SSEClient.lines(for: request) {
            if chunk == "[DONE]" { break }
            guard let data = chunk.data(using: .utf8) else { continue }
            guard let delta = OpenAICompatibleResponseSupport.extractTextDelta(from: data), !delta.isEmpty else {
                if OpenAICompatibleResponseSupport.containsReasoningDelta(data) {
                    continue
                }
                continue
            }
            buffer += delta
            if buffer.count >= 120 { break }
        }

        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        guard !settingsStore.multimodalLLMBaseURL.isEmpty else {
            throw NSError(
                domain: "MultimodalLLMTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Multimodal LLM base URL is not configured."],
            )
        }
        guard let baseURL = URL(string: settingsStore.multimodalLLMBaseURL) else {
            throw NSError(
                domain: "MultimodalLLMTranscriber",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Multimodal LLM base URL is invalid."],
            )
        }

        let model = settingsStore.multimodalLLMModel.isEmpty ? OpenAIAudioModelCatalog.multimodalModels[0] : settingsStore.multimodalLLMModel

        // Build system prompt: persona + vocabulary in one shot
        let vocabularyTerms = VocabularyStore.activeTerms()
        let frontmostBundleIdentifier = frontmostBundleIdentifierProvider()
        let personaPrompt = settingsStore.effectivePersonaPrompt(
            appName: nil,
            bundleIdentifier: frontmostBundleIdentifier,
        )
        let systemPrompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: personaPrompt,
            vocabularyTerms: vocabularyTerms,
            bundleIdentifier: frontmostBundleIdentifier,
        )
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: systemPrompt,
            appLanguage: settingsStore.appLanguage,
        )

        // Encode audio as base64 (done on current async context, not main thread)
        let audioData = try Data(contentsOf: audioFile.fileURL)
        let base64Audio = audioData.base64EncodedString()
        let audioFormat = audioInputFormat(for: audioFile.fileURL)

        NetworkDebugLogger.logMessage(
            """
            Multimodal LLM transcription:
            model=\(model)
            audioPath=\(audioFile.fileURL.path)
            audioFormat=\(audioFormat)
            audioSizeBytes=\(audioData.count)
            hasPersona=\(personaPrompt != nil)
            vocabularyTerms=\(vocabularyTerms.count)
            frontmostBundleIdentifier=\(frontmostBundleIdentifier ?? "<nil>")
            """,
        )

        let request = try makeRequest(
            baseURL: baseURL,
            model: model,
            systemPrompt: effectiveSystemPrompt,
            base64Audio: base64Audio,
            audioFormat: audioFormat,
        )

        NetworkDebugLogger.logRequest(request, bodyDescription: """
        {
          "model": "\(model)",
          "stream": true,
          "messages": [
            {"role": "system", "content": "\(effectiveSystemPrompt)"},
            {"role": "user", "content": [{"type": "input_audio", "format": "\(audioFormat)", "data": "<\(base64Audio.count) chars base64>"}, {"type": "text", "text": "\(Self.audioProcessingInstructionText)"}]}
          ]
        }
        """)

        return try await streamResponse(for: request, onUpdate: onUpdate)
    }

    // MARK: - Private

    private func makeRequest(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        base64Audio: String,
        audioFormat: String,
    ) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !settingsStore.multimodalLLMAPIKey.isEmpty {
            request.setValue("Bearer \(settingsStore.multimodalLLMAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt,
                ],
                [
                    "role": "user",
                    "content": Self.makeUserMessageContent(
                        base64Audio: base64Audio,
                        audioFormat: audioFormat,
                    ),
                ],
            ],
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func makeTestRequest(baseURL: URL, model: String, apiKey: String) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Audio = RemoteSTTTestAudio.wavSilence().base64EncodedString()
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                [
                    "role": "system",
                    "content": "You are validating a speech-to-text configuration. Transcribe the provided audio. If it contains no speech, reply with OK.",
                ],
                [
                    "role": "user",
                    "content": makeUserMessageContent(
                        base64Audio: base64Audio,
                        audioFormat: "wav",
                    ),
                ],
            ],
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func streamResponse(
        for request: URLRequest,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        var buffer = ""

        do {
            for try await chunk in try await SSEClient.lines(for: request) {
                if chunk == "[DONE]" { break }
                guard let data = chunk.data(using: .utf8) else { continue }

                guard let delta = Self.extractDelta(from: data), !delta.isEmpty else {
                    if OpenAICompatibleResponseSupport.containsReasoningDelta(data) {
                        continue
                    }
                    continue
                }
                buffer += delta

                await onUpdate(TranscriptionSnapshot(text: buffer, isFinal: false))
            }
        } catch {
            NetworkDebugLogger.logError(context: "Multimodal LLM stream failed", error: error)
            throw error
        }

        let finalText = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        await onUpdate(TranscriptionSnapshot(text: finalText, isFinal: true))
        NetworkDebugLogger.logMessage("Multimodal LLM final result: \(finalText.isEmpty ? "<empty>" : finalText)")
        return finalText
    }

    private static func extractDelta(from data: Data) -> String? {
        OpenAICompatibleResponseSupport.extractTextDelta(from: data)
    }

    static func makeUserMessageContent(base64Audio: String, audioFormat: String) -> [[String: Any]] {
        [
            [
                "type": "input_audio",
                "input_audio": [
                    "data": base64Audio,
                    "format": audioFormat,
                ],
            ],
            [
                "type": "text",
                "text": audioProcessingInstructionText,
            ],
        ]
    }

    /// Maps a file extension to the format string expected by the OpenAI input_audio API.
    /// m4a is an AAC stream in an MPEG-4 container — OpenAI accepts it as "mp4".
    private func audioInputFormat(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "mp4", "m4a":
            "mp4"
        case "wav":
            "wav"
        case "mp3", "mpeg", "mpga":
            "mp3"
        case "ogg":
            "ogg"
        case "webm":
            "webm"
        case "flac":
            "flac"
        case "aac":
            "aac"
        default:
            // Default to mp4 since the app records in m4a format
            "mp4"
        }
    }
}
