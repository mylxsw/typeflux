import Foundation

final class OpenAICompatibleAgentService: LLMAgentService, @unchecked Sendable {
    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding type: T.Type) async throws -> T {
        guard !request.tools.isEmpty else {
            throw LLMAgentError.noToolsConfigured
        }

        let llmConfig = settingsStore.textLLMConfiguration()
        let connection = try LLMConnectionResolver.resolve(
            provider: llmConfig.provider,
            baseURL: llmConfig.baseURL,
            model: llmConfig.model,
            apiKey: llmConfig.apiKey,
        )
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: request.systemPrompt,
            appLanguage: settingsStore.appLanguage,
        )

        return try await RequestRetry.perform(operationName: "LLM agent tool call") {
            try await RemoteAgentClient.runTool(
                provider: connection.provider,
                baseURL: connection.baseURL,
                model: connection.model,
                apiKey: connection.apiKey,
                additionalHeaders: connection.additionalHeaders,
                request: LLMAgentRequest(
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: request.userPrompt,
                    tools: request.tools,
                    forcedToolName: request.forcedToolName,
                ),
                decoding: type,
            )
        }
    }

    /// Runs a single tool call and returns the raw tool name + arguments without decoding into a specific type.
    /// Use this when the caller needs to dispatch on the tool name (e.g. Phase 1 router with multiple possible tools).
    func runAnyTool(request: LLMAgentRequest) async throws -> LLMAgentToolCall {
        guard !request.tools.isEmpty else {
            throw LLMAgentError.noToolsConfigured
        }

        let llmConfig = settingsStore.textLLMConfiguration()
        let connection = try LLMConnectionResolver.resolve(
            provider: llmConfig.provider,
            baseURL: llmConfig.baseURL,
            model: llmConfig.model,
            apiKey: llmConfig.apiKey,
        )
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: request.systemPrompt,
            appLanguage: settingsStore.appLanguage,
        )

        return try await RequestRetry.perform(operationName: "LLM phase 1 router call") {
            try await RemoteAgentClient.runAnyTool(
                provider: connection.provider,
                baseURL: connection.baseURL,
                model: connection.model,
                apiKey: connection.apiKey,
                additionalHeaders: connection.additionalHeaders,
                request: LLMAgentRequest(
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: request.userPrompt,
                    tools: request.tools,
                    forcedToolName: request.forcedToolName,
                ),
            )
        }
    }
}

enum RemoteAgentClient {
    static func runTool<T: Decodable & Sendable>(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        request: LLMAgentRequest,
        decoding type: T.Type,
    ) async throws -> T {
        switch provider.apiStyle {
        case .openAICompatible:
            try await runOpenAICompatibleTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                request: request,
                decoding: type,
            )
        case .anthropic:
            try await runAnthropicTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                request: request,
                decoding: type,
            )
        case .gemini:
            try await runGeminiTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                request: request,
                decoding: type,
            )
        }
    }

    // MARK: - Typed tool call (decode into T)

    private static func runOpenAICompatibleTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
        decoding type: T.Type,
    ) async throws -> T {
        let toolCall = try await fetchOpenAICompatibleToolCall(
            baseURL: baseURL, model: model, apiKey: apiKey,
            additionalHeaders: additionalHeaders, request: request,
        )
        return try decodeToolArguments(toolCall, expectedToolName: request.forcedToolName, as: type)
    }

    private static func runAnthropicTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
        decoding type: T.Type,
    ) async throws -> T {
        let toolCall = try await fetchAnthropicToolCall(
            baseURL: baseURL, model: model, apiKey: apiKey,
            additionalHeaders: additionalHeaders, request: request,
        )
        return try decodeToolArguments(toolCall, expectedToolName: request.forcedToolName, as: type)
    }

    private static func runGeminiTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
        decoding type: T.Type,
    ) async throws -> T {
        let toolCall = try await fetchGeminiToolCall(
            baseURL: baseURL, model: model, apiKey: apiKey,
            additionalHeaders: additionalHeaders, request: request,
        )
        return try decodeToolArguments(toolCall, expectedToolName: request.forcedToolName, as: type)
    }

    // MARK: - Raw tool call (returns LLMAgentToolCall without decoding)

    /// Returns the raw tool name + arguments without decoding into a specific type.
    /// Used by the Phase 1 router which needs to dispatch on the tool name.
    static func runAnyTool(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        request: LLMAgentRequest,
    ) async throws -> LLMAgentToolCall {
        switch provider.apiStyle {
        case .openAICompatible:
            try await fetchOpenAICompatibleToolCall(
                baseURL: baseURL, model: model, apiKey: apiKey,
                additionalHeaders: additionalHeaders, request: request,
            )
        case .anthropic:
            try await fetchAnthropicToolCall(
                baseURL: baseURL, model: model, apiKey: apiKey,
                additionalHeaders: additionalHeaders, request: request,
            )
        case .gemini:
            try await fetchGeminiToolCall(
                baseURL: baseURL, model: model, apiKey: apiKey,
                additionalHeaders: additionalHeaders, request: request,
            )
        }
    }

    // MARK: - HTTP fetch helpers (provider-specific, return raw LLMAgentToolCall)

    private static func fetchOpenAICompatibleToolCall(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
    ) async throws -> LLMAgentToolCall {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        var body = LLMAgentResponseSupport.openAICompatibleToolBody(
            model: model,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName,
        )
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractOpenAICompatibleToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }
        return toolCall
    }

    private static func fetchAnthropicToolCall(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
    ) async throws -> LLMAgentToolCall {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let body = LLMAgentResponseSupport.anthropicToolBody(
            model: model,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName,
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractAnthropicToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }
        return toolCall
    }

    private static func fetchGeminiToolCall(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        request: LLMAgentRequest,
    ) async throws -> LLMAgentToolCall {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("models/\(model):generateContent"),
            resolvingAgainstBaseURL: false,
        ) else {
            throw NSError(domain: "LLMAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini endpoint."])
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw NSError(domain: "LLMAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini endpoint."])
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let body = LLMAgentResponseSupport.geminiToolBody(
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName,
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractGeminiToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }
        return toolCall
    }

    static func decodeToolArguments<T: Decodable & Sendable>(
        _ toolCall: LLMAgentToolCall,
        expectedToolName: String?,
        as type: T.Type,
    ) throws -> T {
        guard expectedToolName == nil || toolCall.name == expectedToolName else {
            throw LLMAgentError.unexpectedToolName(expected: expectedToolName, actual: toolCall.name)
        }

        guard let argumentsData = toolCall.argumentsJSON.data(using: .utf8) else {
            throw LLMAgentError.invalidToolArguments
        }

        do {
            return try JSONDecoder().decode(type, from: argumentsData)
        } catch {
            throw LLMAgentError.invalidToolArguments
        }
    }
}
