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

        let prompts = PromptCatalog.rewritePrompts(for: rewriteRequest)

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

        return lines(for: bytes)
    }

    static func lines(for bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)

                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer.prefix(upTo: newlineIndex)
                            buffer.removeSubrange(...newlineIndex)

                            guard var line = String(data: lineData, encoding: .utf8) else {
                                continue
                            }

                            if line.hasSuffix("\r") {
                                line.removeLast()
                            }

                            if line.hasPrefix("data:") {
                                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                                continuation.yield(payload)
                            }
                        }
                    }

                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), line.hasPrefix("data:") {
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        continuation.yield(payload)
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
