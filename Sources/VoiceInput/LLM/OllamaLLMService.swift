import Foundation

final class OllamaLLMService: LLMService {
    private let settingsStore: SettingsStore
    private let modelManager: OllamaLocalModelManager

    init(settingsStore: SettingsStore, modelManager: OllamaLocalModelManager) {
        self.settingsStore = settingsStore
        self.modelManager = modelManager
    }

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await modelManager.ensureModelReady(settingsStore: settingsStore)
                    let text = try await streamRewriteInternal(request: request, continuation: continuation)
                    continuation.finish()
                    _ = text
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamRewriteInternal(
        request: LLMRewriteRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> String {
        let base = settingsStore.ollamaBaseURL.isEmpty ? "http://127.0.0.1:11434" : settingsStore.ollamaBaseURL
        guard let baseURL = URL(string: base) else {
            throw NSError(
                domain: "OllamaLLMService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama base URL."]
            )
        }

        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompts = buildPrompts(for: request)
        let body: [String: Any] = [
            "model": settingsStore.ollamaModel,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompts.system],
                ["role": "user", "content": prompts.user]
            ],
            "options": [
                "temperature": 0.4
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        NetworkDebugLogger.logRequest(urlRequest)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaLLMService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama response."]
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }

            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OllamaLLMService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        var buffer = ""
        var finalText = ""

        for try await byte in bytes {
            let scalar = UnicodeScalar(byte)
            buffer.append(Character(scalar))

            guard buffer.hasSuffix("\n") else { continue }
            let line = buffer.trimmingCharacters(in: .newlines)
            buffer = ""

            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }

            let payload = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            if let content = payload.message?.content, !content.isEmpty {
                finalText += content
                continuation.yield(content)
            }

            if payload.done {
                break
            }
        }

        return finalText
    }

    private func buildPrompts(for request: LLMRewriteRequest) -> (system: String, user: String) {
        let personaSection: String
        if let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !personaPrompt.isEmpty {
            personaSection = "\nPersona requirements:\n\(personaPrompt)"
        } else {
            personaSection = ""
        }

        switch request.mode {
        case .editSelection:
            let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outputRequirement: String
            if let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !personaPrompt.isEmpty {
                outputRequirement = """

                Output requirements:
                - Treat the spoken instruction as the highest-priority requirement.
                - Apply the persona requirement below only when it does not conflict with the edit intent.
                - Persona requirement: \(personaPrompt)
                """
            } else {
                outputRequirement = """

                Output requirements:
                - Treat the spoken instruction as the highest-priority requirement.
                """
            }

            return (
                system: "You are a text editing assistant. When editing existing text, preserve the user's editing intent first and use any persona requirement only as a secondary output-style constraint. Return only the final rewritten text without explanations or quotation marks.",
                user: """
                Selected text:
                \(request.sourceText)

                Spoken instruction:
                \(spokenInstruction)\(outputRequirement)

                Return only the final rewritten text.
                """
            )

        case .rewriteTranscript:
            return (
                system: "You rewrite dictated text into polished final copy. Follow the persona requirements exactly when provided. Return only the final text without explanations or quotation marks.",
                user: """
                Raw transcript:
                \(request.sourceText)\(personaSection)

                Clean up recognition artifacts if needed and return only the final text.
                """
            )
        }
    }
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatMessage?
    let done: Bool
}

private struct OllamaChatMessage: Decodable {
    let content: String?
}
