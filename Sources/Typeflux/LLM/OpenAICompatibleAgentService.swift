import Foundation

final class OpenAICompatibleAgentService: LLMAgentService, @unchecked Sendable {
    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func resolveConnection(for config: SettingsStore.TextLLMConfiguration) async throws -> ResolvedLLMConnection {
        if config.provider == .typefluxCloud {
            let token = await MainActor.run { AuthState.shared.accessToken }
            guard let token else {
                throw TypefluxCloudLLMError.notLoggedIn
            }
            let primary = await CloudEndpointRegistry.shared.primaryEndpoint()
            return try LLMConnectionResolver.resolve(
                provider: config.provider,
                baseURL: "",
                model: config.model,
                apiKey: token,
                typefluxCloudBaseURL: primary,
            )
        }
        return try LLMConnectionResolver.resolve(
            provider: config.provider,
            baseURL: config.baseURL,
            model: config.model,
            apiKey: config.apiKey,
        )
    }

    private func headers(
        for connection: ResolvedLLMConnection,
        scenario: TypefluxCloudScenario,
    ) -> [String: String] {
        connection.headers(for: scenario)
    }

    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding type: T.Type) async throws -> T {
        guard !request.tools.isEmpty else {
            throw LLMAgentError.noToolsConfigured
        }

        let llmConfig = settingsStore.textLLMConfiguration()
        let appLanguage = settingsStore.appLanguage
        let effectiveSystemPrompt: String = {
            var prompt = PromptCatalog.appendUserEnvironmentContext(
                to: request.systemPrompt,
                appLanguage: appLanguage,
            )
            if let appContext = request.appSystemContext {
                let extra = PromptCatalog.appSpecificSystemContext(appContext)
                if !extra.isEmpty {
                    prompt = PromptCatalog.appendAdditionalSystemContext(extra, to: prompt)
                }
            }
            return prompt
        }()

        return try await RequestRetry.perform(operationName: "LLM agent tool call") { [weak self] in
            guard let self else { throw CancellationError() }
            let connection = try await self.resolveConnection(for: llmConfig)
            let additionalHeaders = self.headers(for: connection, scenario: .askAnything)
            let cloudBaseURL: URL? = (llmConfig.provider == .typefluxCloud)
                ? await CloudEndpointRegistry.shared.primaryEndpoint()
                : nil
            return try await Self.reportingFailures(cloudBaseURL: cloudBaseURL) {
                try await RemoteAgentClient.runTool(
                    provider: connection.provider,
                    baseURL: connection.baseURL,
                    model: connection.model,
                    apiKey: connection.apiKey,
                    additionalHeaders: additionalHeaders,
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
    }

    /// Runs a single tool call and returns the raw tool name + arguments without decoding into a specific type.
    /// Use this when the caller needs to dispatch on the tool name (e.g. Phase 1 router with multiple possible tools).
    func runAnyTool(request: LLMAgentRequest) async throws -> LLMAgentToolCall {
        guard !request.tools.isEmpty else {
            throw LLMAgentError.noToolsConfigured
        }

        let llmConfig = settingsStore.textLLMConfiguration()
        let appLanguage = settingsStore.appLanguage
        let effectiveSystemPrompt: String = {
            var prompt = PromptCatalog.appendUserEnvironmentContext(
                to: request.systemPrompt,
                appLanguage: appLanguage,
            )
            if let appContext = request.appSystemContext {
                let extra = PromptCatalog.appSpecificSystemContext(appContext)
                if !extra.isEmpty {
                    prompt = PromptCatalog.appendAdditionalSystemContext(extra, to: prompt)
                }
            }
            return prompt
        }()

        return try await RequestRetry.perform(operationName: "LLM phase 1 router call") { [weak self] in
            guard let self else { throw CancellationError() }
            let connection = try await self.resolveConnection(for: llmConfig)
            let additionalHeaders = self.headers(for: connection, scenario: .askAnything)
            let cloudBaseURL: URL? = (llmConfig.provider == .typefluxCloud)
                ? await CloudEndpointRegistry.shared.primaryEndpoint()
                : nil
            return try await Self.reportingFailures(cloudBaseURL: cloudBaseURL) {
                try await RemoteAgentClient.runAnyTool(
                    provider: connection.provider,
                    baseURL: connection.baseURL,
                    model: connection.model,
                    apiKey: connection.apiKey,
                    additionalHeaders: additionalHeaders,
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

    static func reportingFailures<T>(cloudBaseURL: URL?, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cloudBaseURL {
                await CloudEndpointRegistry.shared.reportFailure(cloudBaseURL, error: error)
            }
            throw error
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
        AgentRequestConfiguration.apply(to: &urlRequest)
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
            if let text = LLMAgentResponseSupport.extractOpenAICompatibleText(from: data) {
                throw LLMAgentError.textResponse(text: text)
            }
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
        AgentRequestConfiguration.apply(to: &urlRequest)
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
            if let text = LLMAgentResponseSupport.extractAnthropicText(from: data) {
                throw LLMAgentError.textResponse(text: text)
            }
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
        AgentRequestConfiguration.apply(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let body = LLMAgentResponseSupport.geminiToolBody(
            model: model,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName,
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractGeminiToolCall(from: data) else {
            if let text = LLMAgentResponseSupport.extractGeminiText(from: data) {
                throw LLMAgentError.textResponse(text: text)
            }
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
