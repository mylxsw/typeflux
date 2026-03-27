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

        let prompts = PromptCatalog.rewritePrompts(for: request)
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
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatMessage?
    let done: Bool
}

private struct OllamaChatMessage: Decodable {
    let content: String?
}
