import Foundation

struct ResolvedLLMConnection {
    let provider: LLMRemoteProvider
    let baseURL: URL
    let model: String
    let apiKey: String
    let additionalHeaders: [String: String]
}

enum LLMConnectionResolver {
    static func resolve(
        provider: LLMRemoteProvider,
        baseURL: String,
        model: String,
        apiKey: String,
    ) throws -> ResolvedLLMConnection {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        if provider == .freeModel {
            guard !trimmedModel.isEmpty else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L("settings.models.freeModel.validation.emptyModel"),
                    ],
                )
            }
            guard let resolved = FreeLLMModelRegistry.resolve(modelName: trimmedModel) else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L(
                            "settings.models.freeModel.validation.unsupportedModel",
                            trimmedModel,
                        ),
                    ],
                )
            }
            guard let url = URL(string: resolved.baseURL), !resolved.baseURL.isEmpty else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L("settings.models.freeModel.validation.invalidEndpoint"),
                    ],
                )
            }
            return ResolvedLLMConnection(
                provider: provider,
                baseURL: url,
                model: resolved.modelName,
                apiKey: resolved.apiKey,
                additionalHeaders: resolved.additionalHeaders,
            )
        }

        guard
            !trimmedBaseURL.isEmpty,
            let url = URL(string: trimmedBaseURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw NSError(
                domain: "LLM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid LLM base URL."],
            )
        }

        return ResolvedLLMConnection(
            provider: provider,
            baseURL: url,
            model: trimmedModel.isEmpty ? provider.defaultModel : trimmedModel,
            apiKey: apiKey,
            additionalHeaders: [:],
        )
    }
}

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

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let llmConfig = settingsStore.textLLMConfiguration()
        let connection = try LLMConnectionResolver.resolve(
            provider: llmConfig.provider,
            baseURL: llmConfig.baseURL,
            model: llmConfig.model,
            apiKey: llmConfig.apiKey,
        )
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: systemPrompt,
            appLanguage: settingsStore.appLanguage,
        )
        return try await RequestRetry.perform(operationName: "LLM completion request") {
            try await RemoteLLMClient.complete(
                provider: connection.provider,
                baseURL: connection.baseURL,
                model: connection.model,
                apiKey: connection.apiKey,
                additionalHeaders: connection.additionalHeaders,
                systemPrompt: effectiveSystemPrompt,
                userPrompt: userPrompt,
                schema: nil,
            )
        }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        let llmConfig = settingsStore.textLLMConfiguration()
        let connection = try LLMConnectionResolver.resolve(
            provider: llmConfig.provider,
            baseURL: llmConfig.baseURL,
            model: llmConfig.model,
            apiKey: llmConfig.apiKey,
        )
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: systemPrompt,
            appLanguage: settingsStore.appLanguage,
        )
        return try await RequestRetry.perform(operationName: "LLM JSON completion request") {
            try await RemoteLLMClient.complete(
                provider: connection.provider,
                baseURL: connection.baseURL,
                model: connection.model,
                apiKey: connection.apiKey,
                additionalHeaders: connection.additionalHeaders,
                systemPrompt: effectiveSystemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        }
    }

    private func streamRewriteInternal(
        request rewriteRequest: LLMRewriteRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
    ) async throws -> String {
        let llmConfig = settingsStore.textLLMConfiguration()
        let connection = try LLMConnectionResolver.resolve(
            provider: llmConfig.provider,
            baseURL: llmConfig.baseURL,
            model: llmConfig.model,
            apiKey: llmConfig.apiKey,
        )

        let prompts = PromptCatalog.rewritePrompts(for: rewriteRequest)
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: prompts.system,
            appLanguage: settingsStore.appLanguage,
        )

        let final = try await RemoteLLMClient.streamRewrite(
            provider: connection.provider,
            baseURL: connection.baseURL,
            model: connection.model,
            apiKey: connection.apiKey,
            additionalHeaders: connection.additionalHeaders,
            systemPrompt: effectiveSystemPrompt,
            userPrompt: prompts.user,
            continuation: continuation,
        )

        NetworkDebugLogger.logMessage("LLM final result: \(final.isEmpty ? "<empty stream result>" : final)")

        return final
    }
}

enum RemoteLLMClient {
    static func streamRewrite(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        systemPrompt: String,
        userPrompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
    ) async throws -> String {
        switch provider.apiStyle {
        case .openAICompatible:
            return try await streamOpenAICompatible(
                provider: provider,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                continuation: continuation,
            )
        case .anthropic:
            let text = try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: nil,
            )
            if !text.isEmpty {
                continuation.yield(text)
            }
            return text
        case .gemini:
            let text = try await requestGemini(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: nil,
            )
            if !text.isEmpty {
                continuation.yield(text)
            }
            return text
        }
    }

    static func previewConnection(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
    ) async throws -> String {
        switch provider.apiStyle {
        case .openAICompatible:
            try await previewOpenAICompatible(
                provider: provider,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
            )
        case .anthropic:
            try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: "Reply with a short greeting.",
                userPrompt: "Hello",
                schema: nil,
            )
        case .gemini:
            try await requestGemini(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: "Reply with a short greeting.",
                userPrompt: "Hello",
                schema: nil,
            )
        }
    }

    static func complete(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?,
    ) async throws -> String {
        switch provider.apiStyle {
        case .openAICompatible:
            try await requestOpenAICompatible(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        case .anthropic:
            try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        case .gemini:
            try await requestGemini(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        }
    }

    private static func streamOpenAICompatible(
        provider _: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
    ) async throws -> String {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        NetworkDebugLogger.logRequest(urlRequest)

        var final = ""
        var thinkingFilter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()

        do {
            for try await line in try await SSEClient.lines(for: urlRequest) {
                if line == "[DONE]" { break }

                guard let data = line.data(using: .utf8) else { continue }
                let content = OpenAICompatibleResponseSupport.extractTextDelta(from: data)
                if let content, !content.isEmpty {
                    if let filtered = thinkingFilter.process(content) {
                        final += filtered
                        continuation.yield(filtered)
                    }
                } else if OpenAICompatibleResponseSupport.containsReasoningDelta(data) {
                    continue
                }
            }
            if let remaining = thinkingFilter.flush() {
                final += remaining
                continuation.yield(remaining)
            }
        } catch {
            NetworkDebugLogger.logError(context: "LLM stream failed", error: error)
            throw error
        }

        return final
    }

    private static func previewOpenAICompatible(
        provider _: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
    ) async throws -> String {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_completion_tokens": 50,
            "messages": [["role": "user", "content": "Hello"]],
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var collected = ""
        for try await chunk in try await SSEClient.lines(for: urlRequest) {
            if chunk == "[DONE]" { break }
            guard let data = chunk.data(using: .utf8) else { continue }
            if let content = OpenAICompatibleResponseSupport.extractTextDelta(from: data), !content.isEmpty {
                collected += content
                if collected.count >= 60 {
                    break
                }
            }
        }
        return collected
    }

    private static func requestOpenAICompatible(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?,
    ) async throws -> String {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        if let schema, providerSupportsResponseFormat(baseURL: baseURL) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schema.name,
                    "strict": schema.strict,
                    "schema": schema.jsonObject,
                ],
            ]
        }
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performJSONRequest(urlRequest)
        let raw = OpenAICompatibleResponseSupport.extractTextDelta(from: data)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OpenAICompatibleResponseSupport.stripLeadingThinkingTags(raw)
    }

    private static func requestAnthropic(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?,
    ) async throws -> String {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": anthropicSystemPrompt(systemPrompt: systemPrompt, schema: schema),
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": anthropicUserPrompt(userPrompt: userPrompt, schema: schema)],
                    ],
                ],
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performJSONRequest(urlRequest)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]]
        else {
            return ""
        }

        return joinTextBlocks(content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        })
    }

    private static func requestGemini(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?,
    ) async throws -> String {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("models/\(model):generateContent"), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini endpoint."])
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini endpoint."])
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)
        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userPrompt]],
                ],
            ],
            "generationConfig": [
                "candidateCount": 1,
                "maxOutputTokens": 1024,
            ],
        ]
        if let schema {
            body["generationConfig"] = [
                "candidateCount": 1,
                "maxOutputTokens": 1024,
                "responseMimeType": "application/json",
                "responseSchema": schema.jsonObject,
            ]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performJSONRequest(urlRequest)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            return ""
        }

        return joinTextBlocks(parts.compactMap { $0["text"] as? String })
    }

    private static func providerSupportsResponseFormat(baseURL: URL) -> Bool {
        let host = baseURL.host?.lowercased() ?? ""
        return host == "api.openai.com"
            || host.hasSuffix(".openai.com")
    }

    private static func anthropicSystemPrompt(systemPrompt: String, schema: LLMJSONSchema?) -> String {
        guard let schema else { return systemPrompt }
        return """
        \(systemPrompt)

        Return JSON only. Do not wrap it in Markdown code fences.
        The JSON must match this schema exactly:
        \(schema.jsonObject.prettyPrintedJSONString ?? "{}")
        """
    }

    private static func anthropicUserPrompt(userPrompt: String, schema: LLMJSONSchema?) -> String {
        guard schema != nil else { return userPrompt }
        return """
        \(userPrompt)

        Return only valid JSON matching the required schema.
        """
    }

    private static func joinTextBlocks(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }

        return parts.enumerated().reduce(into: "") { partial, item in
            let segment = item.element.trimmingCharacters(in: .newlines)
            guard !segment.isEmpty else { return }

            if item.offset == 0 {
                partial = segment
            } else {
                partial += "\n\n" + segment
            }
        }
    }

    private static func applyAdditionalHeaders(
        _ headers: [String: String],
        to request: inout URLRequest,
    ) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    static func performJSONRequest(_ request: URLRequest) async throws -> Data {
        NetworkDebugLogger.logRequest(request)
        let (data, response) = try await URLSession.shared.data(for: request)
        NetworkDebugLogger.logResponse(response, data: data)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response."])
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "LLM", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(message)"])
        }
        return data
    }
}

enum SSEClient {
    static func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, bodyDescription: "<invalid non-http response>")
            throw NSError(domain: "SSE", code: 1)
        }

        if !(200 ..< 300).contains(http.statusCode) {
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
        AsyncThrowingStream { continuation in
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

private extension [String: Any] {
    var prettyPrintedJSONString: String? {
        guard JSONSerialization.isValidJSONObject(self),
              let data = try? JSONSerialization.data(withJSONObject: self, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
