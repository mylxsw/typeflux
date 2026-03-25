import Foundation

final class OpenAICompatibleLLMService: LLMService {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func streamRewrite(request rewriteRequest: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await streamRewriteInternal(request: rewriteRequest, continuation: continuation)
                    continuation.finish()
                    _ = text
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamRewriteInternal(
        request rewriteRequest: LLMRewriteRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> String {
        guard let baseURL = URL(string: settingsStore.llmBaseURL), !settingsStore.llmBaseURL.isEmpty else {
            throw NSError(domain: "LLM", code: 1)
        }

        let model = settingsStore.llmModel.isEmpty ? "gpt-4o-mini" : settingsStore.llmModel

        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !settingsStore.llmAPIKey.isEmpty {
            urlRequest.setValue("Bearer \(settingsStore.llmAPIKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompts = buildPrompts(for: rewriteRequest)

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompts.system],
                ["role": "user", "content": prompts.user]
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        NetworkDebugLogger.logRequest(urlRequest)

        var final = ""

        do {
            for try await line in try await SSEClient.lines(for: urlRequest) {
                if line == "[DONE]" { break }

                guard let data = line.data(using: .utf8) else { continue }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                let choices = obj?["choices"] as? [[String: Any]]
                let delta = choices?.first?["delta"] as? [String: Any]
                let content = delta?["content"] as? String
                if let content {
                    final += content
                    continuation.yield(content)
                }
            }
        } catch {
            NetworkDebugLogger.logError(context: "LLM stream failed", error: error)
            throw error
        }

        NetworkDebugLogger.logMessage("LLM final result: \(final.isEmpty ? "<empty stream result>" : final)")

        return final
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

enum SSEClient {
    static func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, bodyDescription: "<invalid non-http response>")
            throw NSError(domain: "SSE", code: 1)
        }

        if !(200..<300).contains(http.statusCode) {
            var errorBodyData = Data()
            for try await byte in bytes {
                errorBodyData.append(byte)
            }
            NetworkDebugLogger.logResponse(http, data: errorBodyData)
            let errorBody = String(data: errorBodyData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SSE", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"])
        }

        NetworkDebugLogger.logResponse(http, bodyDescription: "<stream opened>")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = ""
                    for try await byte in bytes {
                        let scalar = UnicodeScalar(byte)
                        buffer.append(Character(scalar))
                        if buffer.hasSuffix("\n") {
                            let line = buffer.trimmingCharacters(in: .newlines)
                            buffer = ""

                            if line.hasPrefix("data:") {
                                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                                continuation.yield(payload)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    NetworkDebugLogger.logError(context: "SSE stream parsing failed", error: error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
