import Foundation

final class OpenAICompatibleAgentService: LLMAgentService {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding type: T.Type) async throws -> T {
        guard !request.tools.isEmpty else {
            throw LLMAgentError.noToolsConfigured
        }

        let remoteProvider = settingsStore.llmRemoteProvider
        let configuredBaseURL = settingsStore.llmBaseURL
        guard let baseURL = URL(string: configuredBaseURL), !configuredBaseURL.isEmpty else {
            throw NSError(domain: "LLMAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid LLM base URL."])
        }

        let model = settingsStore.llmModel.isEmpty ? remoteProvider.defaultModel : settingsStore.llmModel
        let effectiveSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: request.systemPrompt,
            appLanguage: settingsStore.appLanguage
        )

        return try await RequestRetry.perform(operationName: "LLM agent tool call") { [self] in
            try await RemoteAgentClient.runTool(
                provider: remoteProvider,
                baseURL: baseURL,
                model: model,
                apiKey: self.settingsStore.llmAPIKey,
                request: LLMAgentRequest(
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: request.userPrompt,
                    tools: request.tools,
                    forcedToolName: request.forcedToolName
                ),
                decoding: type
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
        request: LLMAgentRequest,
        decoding type: T.Type
    ) async throws -> T {
        switch provider.apiStyle {
        case .openAICompatible:
            return try await runOpenAICompatibleTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                request: request,
                decoding: type
            )
        case .anthropic:
            return try await runAnthropicTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                request: request,
                decoding: type
            )
        case .gemini:
            return try await runGeminiTool(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                request: request,
                decoding: type
            )
        }
    }

    private static func runOpenAICompatibleTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        request: LLMAgentRequest,
        decoding type: T.Type
    ) async throws -> T {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body = LLMAgentResponseSupport.openAICompatibleToolBody(
            model: model,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName
        )
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractOpenAICompatibleToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }

        return try decodeToolArguments(
            toolCall,
            expectedToolName: request.forcedToolName,
            as: type
        )
    }

    private static func runAnthropicTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        request: LLMAgentRequest,
        decoding type: T.Type
    ) async throws -> T {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = LLMAgentResponseSupport.anthropicToolBody(
            model: model,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractAnthropicToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }

        return try decodeToolArguments(
            toolCall,
            expectedToolName: request.forcedToolName,
            as: type
        )
    }

    private static func runGeminiTool<T: Decodable & Sendable>(
        baseURL: URL,
        model: String,
        apiKey: String,
        request: LLMAgentRequest,
        decoding type: T.Type
    ) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("models/\(model):generateContent"),
            resolvingAgainstBaseURL: false
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
        let body = LLMAgentResponseSupport.geminiToolBody(
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: request.tools,
            forcedToolName: request.forcedToolName
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(urlRequest)
        guard let toolCall = LLMAgentResponseSupport.extractGeminiToolCall(from: data) else {
            throw LLMAgentError.missingToolCall
        }

        return try decodeToolArguments(
            toolCall,
            expectedToolName: request.forcedToolName,
            as: type
        )
    }

    static func decodeToolArguments<T: Decodable & Sendable>(
        _ toolCall: LLMAgentToolCall,
        expectedToolName: String?,
        as type: T.Type
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
