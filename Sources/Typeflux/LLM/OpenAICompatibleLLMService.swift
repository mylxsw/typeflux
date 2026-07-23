import Foundation

// MARK: - Typeflux Cloud LLM Error

enum TypefluxCloudLLMError: LocalizedError {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Please sign in to use Typeflux Cloud language model."
        }
    }
}

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
        typefluxCloudBaseURL: URL? = nil
    ) throws -> ResolvedLLMConnection {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        // typefluxCloud uses the server URL + Bearer token injected at call time
        if provider == .typefluxCloud {
            let rawBase: URL
            if let typefluxCloudBaseURL {
                rawBase = typefluxCloudBaseURL
            } else {
                guard let fallback = URL(string: AppServerConfiguration.apiBaseURL) else {
                    throw NSError(
                        domain: "LLM",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid Typeflux Cloud server URL."]
                    )
                }
                rawBase = fallback
            }
            let url = AuthEndpointResolver.resolve(baseURL: rawBase, path: "/api/v1")
            return ResolvedLLMConnection(
                provider: provider,
                baseURL: url,
                model: trimmedModel.isEmpty ? "default" : trimmedModel,
                apiKey: apiKey,
                additionalHeaders: [:]
            )
        }

        if provider == .freeModel {
            guard !trimmedModel.isEmpty else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L("settings.models.freeModel.validation.emptyModel")
                    ]
                )
            }
            guard let resolved = FreeLLMModelRegistry.resolve(modelName: trimmedModel) else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L(
                            "settings.models.freeModel.validation.unsupportedModel",
                            trimmedModel
                        )
                    ]
                )
            }
            guard let url = URL(string: resolved.baseURL), !resolved.baseURL.isEmpty else {
                throw NSError(
                    domain: "LLM",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: L("settings.models.freeModel.validation.invalidEndpoint")
                    ]
                )
            }
            return ResolvedLLMConnection(
                provider: provider,
                baseURL: url,
                model: resolved.modelName,
                apiKey: resolved.apiKey,
                additionalHeaders: resolved.additionalHeaders
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
                userInfo: [NSLocalizedDescriptionKey: "Invalid LLM base URL."]
            )
        }

        return ResolvedLLMConnection(
            provider: provider,
            baseURL: url,
            model: trimmedModel.isEmpty ? provider.defaultModel : trimmedModel,
            apiKey: apiKey,
            additionalHeaders: [:]
        )
    }
}

final class OpenAICompatibleLLMService: LLMService {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Connection plus the raw cloud base URL (no `/api/v1` suffix) when
    /// applicable. The raw URL is used to report transport failures back to
    /// `CloudEndpointSelector` so subsequent attempts pick a different host.
    private struct ResolvedLLMCall {
        let connection: ResolvedLLMConnection
        let cloudBaseURL: URL?
    }

    private func resolveConnection(for config: SettingsStore.TextLLMConfiguration) async throws -> ResolvedLLMCall {
        if config.provider == .typefluxCloud {
            let token = await MainActor.run { AuthState.shared.accessToken }
            guard let token else {
                throw TypefluxCloudLLMError.notLoggedIn
            }
            let primary = await CloudEndpointRegistry.shared.latencyOptimizedEndpoint()
            let connection = try LLMConnectionResolver.resolve(
                provider: config.provider,
                baseURL: "",
                model: config.model,
                apiKey: token,
                typefluxCloudBaseURL: primary
            )
            return ResolvedLLMCall(connection: connection, cloudBaseURL: primary)
        }
        let connection = try LLMConnectionResolver.resolve(
            provider: config.provider,
            baseURL: config.baseURL,
            model: config.model,
            apiKey: config.apiKey
        )
        return ResolvedLLMCall(connection: connection, cloudBaseURL: nil)
    }

    private func headers(
        for connection: ResolvedLLMConnection,
        scenario: TypefluxCloudScenario,
        personaID: UUID? = nil
    ) -> [String: String] {
        connection.headers(for: scenario, personaID: personaID)
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
        let appLanguage = settingsStore.appLanguage
        let effectiveSystemPrompt = PromptCatalog.appendLanguageResolutionPolicy(
            to: systemPrompt
        )
        let effectiveUserPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: userPrompt,
            appLanguage: appLanguage
        )
        return try await RequestRetry.perform(operationName: "LLM completion request") { [weak self] in
            guard let self else { throw CancellationError() }
            // Re-resolve on each attempt so typefluxCloud retries pick up the
            // current lowest-latency endpoint when an earlier attempt failed.
            let call = try await resolveConnection(for: llmConfig)
            let additionalHeaders = headers(for: call.connection, scenario: .askAnything)
            return try await runWithFailureReporting(cloudBaseURL: call.cloudBaseURL) {
                try await RemoteLLMClient.complete(
                    provider: call.connection.provider,
                    baseURL: call.connection.baseURL,
                    model: call.connection.model,
                    apiKey: call.connection.apiKey,
                    additionalHeaders: additionalHeaders,
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: effectiveUserPrompt,
                    schema: nil
                )
            }
        }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        let llmConfig = settingsStore.textLLMConfiguration()
        let appLanguage = settingsStore.appLanguage
        let effectiveSystemPrompt = PromptCatalog.appendLanguageResolutionPolicy(
            to: systemPrompt
        )
        let effectiveUserPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: userPrompt,
            appLanguage: appLanguage
        )
        return try await RequestRetry.perform(operationName: "LLM JSON completion request") { [weak self] in
            guard let self else { throw CancellationError() }
            let call = try await resolveConnection(for: llmConfig)
            let additionalHeaders = headers(for: call.connection, scenario: .automaticVocabulary)
            return try await runWithFailureReporting(cloudBaseURL: call.cloudBaseURL) {
                try await RemoteLLMClient.complete(
                    provider: call.connection.provider,
                    baseURL: call.connection.baseURL,
                    model: call.connection.model,
                    apiKey: call.connection.apiKey,
                    additionalHeaders: additionalHeaders,
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: effectiveUserPrompt,
                    schema: schema
                )
            }
        }
    }

    /// Runs `operation` and reports transport failures for typefluxCloud calls
    /// so subsequent retries pick a different host. Success cases intentionally
    /// do not report here because the LLM client does not measure request
    /// latency; the periodic ping probe is authoritative for latency.
    private func runWithFailureReporting<T>(
        cloudBaseURL: URL?,
        operation: () async throws -> T
    ) async throws -> T {
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

    private func streamRewriteInternal(
        request rewriteRequest: LLMRewriteRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> String {
        let llmConfig = settingsStore.textLLMConfiguration()
        let call = try await resolveConnection(for: llmConfig)
        let additionalHeaders = headers(
            for: call.connection,
            scenario: .textRewrite,
            personaID: rewriteRequest.personaID
        )

        let prompts = PromptCatalog.rewritePrompts(for: rewriteRequest)
        var effectiveSystemPrompt = PromptCatalog.appendLanguageResolutionPolicy(
            to: prompts.system
        )
        let effectiveUserPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: prompts.user,
            appLanguage: settingsStore.appLanguage
        )
        if let appContext = rewriteRequest.appSystemContext {
            let extra = PromptCatalog.appSpecificSystemContext(appContext)
            if !extra.isEmpty {
                effectiveSystemPrompt = PromptCatalog.appendAdditionalSystemContext(
                    extra,
                    to: effectiveSystemPrompt
                )
            }
        }
        NetworkDebugLogger.logMessage(
            PromptCatalog.rewritePromptDebugDescription(
                system: effectiveSystemPrompt,
                user: effectiveUserPrompt
            )
        )

        let final = try await runWithFailureReporting(cloudBaseURL: call.cloudBaseURL) {
            try await RemoteLLMClient.streamRewrite(
                provider: call.connection.provider,
                baseURL: call.connection.baseURL,
                model: call.connection.model,
                apiKey: call.connection.apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: effectiveSystemPrompt,
                userPrompt: effectiveUserPrompt,
                diagnosticsRecorder: rewriteRequest.diagnosticsRecorder,
                continuation: continuation
            )
        }

        NetworkDebugLogger.logMessage("LLM final result: \(final.isEmpty ? "<empty stream result>" : final)")

        return final
    }
}

enum RemoteLLMClient {
    static let customThinkingTuningStore = LLMThinkingTuningAdaptationStore()

    static func streamRewrite(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        systemPrompt: String,
        userPrompt: String,
        diagnosticsRecorder: LLMRequestDiagnosticsRecorder? = nil,
        continuation: AsyncThrowingStream<String, Error>.Continuation
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
                diagnosticsRecorder: diagnosticsRecorder,
                continuation: continuation
            )
        case .anthropic:
            let text = try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: nil
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
                schema: nil
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
        additionalHeaders: [String: String] = [:]
    ) async throws -> String {
        switch provider.apiStyle {
        case .openAICompatible:
            try await previewOpenAICompatible(
                provider: provider,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders
            )
        case .anthropic:
            try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: "Reply with a short greeting.",
                userPrompt: "Hello",
                schema: nil
            )
        case .gemini:
            try await requestGemini(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: "Reply with a short greeting.",
                userPrompt: "Hello",
                schema: nil
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
        schema: LLMJSONSchema?
    ) async throws -> String {
        switch provider.apiStyle {
        case .openAICompatible:
            try await requestOpenAICompatible(
                provider: provider,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema
            )
        case .anthropic:
            try await requestAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema
            )
        case .gemini:
            try await requestGemini(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                additionalHeaders: additionalHeaders,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema
            )
        }
    }

    private static func streamOpenAICompatible(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        diagnosticsRecorder: LLMRequestDiagnosticsRecorder?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
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
                ["role": "user", "content": userPrompt]
            ]
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: baseURL,
            model: model,
            provider: provider
        )
        let baseBody = body
        let tuningCandidate = applyCustomThinkingTuning(
            body: &body,
            provider: provider,
            baseURL: baseURL
        )

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        NetworkDebugLogger.logRequest(urlRequest)

        var currentRequest = urlRequest
        var currentCandidate = tuningCandidate

        while true {
            var final = ""
            var thinkingFilter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
            var usedCandidate = currentCandidate
            var observedReasoning = false

            do {
                let stream = try await sseLinesWithCustomThinkingAdaptation(
                    currentRequest,
                    baseBody: baseBody,
                    provider: provider,
                    baseURL: baseURL,
                    model: model,
                    diagnosticsRecorder: diagnosticsRecorder,
                    candidate: currentCandidate
                )
                usedCandidate = stream.candidate
                for try await line in stream.lines {
                    if line == "[DONE]" { break }

                    let parseStartedAt = Date()
                    guard let data = line.data(using: .utf8) else { continue }
                    if let streamError = OpenAICompatibleResponseSupport.streamError(from: data) {
                        diagnosticsRecorder?.recordJSONParsing(
                            id: stream.attemptID,
                            duration: Date().timeIntervalSince(parseStartedAt),
                            producedOutput: false
                        )
                        throw streamError
                    }
                    let content = OpenAICompatibleResponseSupport.extractTextDelta(from: data)
                    diagnosticsRecorder?.recordJSONParsing(
                        id: stream.attemptID,
                        duration: Date().timeIntervalSince(parseStartedAt),
                        producedOutput: !(content?.isEmpty ?? true)
                    )
                    if let content, !content.isEmpty {
                        if let filtered = thinkingFilter.process(content) {
                            final += filtered
                            continuation.yield(filtered)
                        }
                    } else if OpenAICompatibleResponseSupport.containsReasoningDelta(data) {
                        observedReasoning = true
                        continue
                    }
                }
                if let remaining = thinkingFilter.flush() {
                    final += remaining
                    continuation.yield(remaining)
                }
                recordCustomThinkingTuningSuccess(
                    provider: provider,
                    baseURL: baseURL,
                    candidate: usedCandidate,
                    containsThinking: observedReasoning || thinkingFilter.observedThinking
                )
                return final
            } catch {
                NetworkDebugLogger.logError(context: "LLM stream failed", error: error)
                guard final.isEmpty,
                      let next = try nextCustomThinkingRetry(
                          after: error,
                          provider: provider,
                          baseURL: baseURL,
                          failedCandidate: usedCandidate,
                          originalRequest: urlRequest,
                          baseBody: baseBody
                      )
                else {
                    throw error
                }
                currentRequest = next.request
                currentCandidate = next.candidate
            }
        }
    }

    private static func previewOpenAICompatible(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String]
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
            "messages": [["role": "user", "content": "Hello"]]
        ]
        OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: baseURL,
            model: model,
            provider: provider
        )
        let baseBody = body
        let tuningCandidate = applyCustomThinkingTuning(
            body: &body,
            provider: provider,
            baseURL: baseURL
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var currentRequest = urlRequest
        var currentCandidate = tuningCandidate

        while true {
            var collected = ""
            var thinkingFilter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
            var observedReasoning = false
            var usedCandidate = currentCandidate

            do {
                let stream = try await sseLinesWithCustomThinkingAdaptation(
                    currentRequest,
                    baseBody: baseBody,
                    provider: provider,
                    baseURL: baseURL,
                    model: model,
                    diagnosticsRecorder: nil,
                    candidate: currentCandidate
                )
                usedCandidate = stream.candidate
                for try await chunk in stream.lines {
                    if chunk == "[DONE]" { break }
                    guard let data = chunk.data(using: .utf8) else { continue }
                    if let streamError = OpenAICompatibleResponseSupport.streamError(from: data) {
                        throw streamError
                    }
                    if let content = OpenAICompatibleResponseSupport.extractTextDelta(from: data), !content.isEmpty {
                        let filtered = thinkingFilter.process(content) ?? ""
                        collected += filtered
                        if collected.count >= 60 {
                            break
                        }
                    } else if OpenAICompatibleResponseSupport.containsReasoningDelta(data) {
                        observedReasoning = true
                    }
                }
                recordCustomThinkingTuningSuccess(
                    provider: provider,
                    baseURL: baseURL,
                    candidate: usedCandidate,
                    containsThinking: observedReasoning || thinkingFilter.observedThinking
                )
                return collected
            } catch {
                guard collected.isEmpty,
                      let next = try nextCustomThinkingRetry(
                          after: error,
                          provider: provider,
                          baseURL: baseURL,
                          failedCandidate: usedCandidate,
                          originalRequest: urlRequest,
                          baseBody: baseBody
                      )
                else {
                    throw error
                }
                currentRequest = next.request
                currentCandidate = next.candidate
            }
        }
    }

    private static func requestOpenAICompatible(
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?
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
                ["role": "user", "content": userPrompt]
            ]
        ]
        if let schema, providerSupportsResponseFormat(baseURL: baseURL) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schema.name,
                    "strict": schema.strict,
                    "schema": schema.jsonObject
                ]
            ]
        }
        OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: baseURL,
            model: model,
            provider: provider
        )
        let baseBody = body
        let tuningCandidate = applyCustomThinkingTuning(
            body: &body,
            provider: provider,
            baseURL: baseURL
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result = try await performJSONRequestWithCustomThinkingAdaptation(
            urlRequest,
            baseBody: baseBody,
            provider: provider,
            baseURL: baseURL,
            candidate: tuningCandidate
        )
        let raw = OpenAICompatibleResponseSupport.extractTextDelta(from: result.data)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        recordCustomThinkingTuningSuccess(
            provider: provider,
            baseURL: baseURL,
            candidate: result.candidate,
            containsThinking: OpenAICompatibleResponseSupport.containsLeadingThinkingTags(raw)
        )
        return OpenAICompatibleResponseSupport.stripLeadingThinkingTags(raw)
    }

    private static func requestAnthropic(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        systemPrompt: String,
        userPrompt: String,
        schema: LLMJSONSchema?
    ) async throws -> String {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAdditionalHeaders(additionalHeaders, to: &urlRequest)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": anthropicSystemPrompt(systemPrompt: systemPrompt, schema: schema),
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": anthropicUserPrompt(userPrompt: userPrompt, schema: schema)]
                    ]
                ]
            ]
        ]
        OpenAICompatibleResponseSupport.applyAnthropicTuning(body: &body)
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
        schema: LLMJSONSchema?
    ) async throws -> String {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("models/\(model):generateContent"),
            resolvingAgainstBaseURL: false
        ) else {
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
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userPrompt]]
                ]
            ],
            "generationConfig": [
                "candidateCount": 1,
                "maxOutputTokens": 1024
            ]
        ]
        if var generationConfig = body["generationConfig"] as? [String: Any] {
            OpenAICompatibleResponseSupport.applyGeminiTuning(generationConfig: &generationConfig, model: model)
            body["generationConfig"] = generationConfig
        }
        if let schema {
            var generationConfig: [String: Any] = [
                "candidateCount": 1,
                "maxOutputTokens": 1024,
                "responseMimeType": "application/json",
                "responseSchema": schema.jsonObject
            ]
            OpenAICompatibleResponseSupport.applyGeminiTuning(generationConfig: &generationConfig, model: model)
            body["generationConfig"] = generationConfig
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
        to request: inout URLRequest
    ) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    static func performJSONRequest(_ request: URLRequest) async throws -> Data {
        NetworkDebugLogger.logRequest(request)
        let (data, response) = try await LLMHTTPSession.shared.data(for: request)
        NetworkDebugLogger.logResponse(response, data: data)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response."])
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let billingError = TypefluxCloudBillingError.fromHTTPStatus(http.statusCode, bodyData: data) {
                throw billingError
            }
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "LLM",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(message)"]
            )
        }
        return data
    }

    struct CustomThinkingJSONResult {
        let data: Data
        let candidate: LLMThinkingTuningCandidate?
    }

    struct CustomThinkingStreamResult {
        let lines: AsyncThrowingStream<String, Error>
        let candidate: LLMThinkingTuningCandidate?
        let attemptID: UUID
    }

    static func performJSONRequestWithCustomThinkingAdaptation(
        _ request: URLRequest,
        baseBody: [String: Any],
        provider: LLMRemoteProvider,
        baseURL: URL,
        candidate: LLMThinkingTuningCandidate?
    ) async throws -> CustomThinkingJSONResult {
        var currentRequest = request
        var currentCandidate = candidate

        while true {
            do {
                let data = try await performJSONRequest(currentRequest)
                return CustomThinkingJSONResult(data: data, candidate: currentCandidate)
            } catch {
                guard let next = try nextCustomThinkingRetry(
                    after: error,
                    provider: provider,
                    baseURL: baseURL,
                    failedCandidate: currentCandidate,
                    originalRequest: request,
                    baseBody: baseBody
                ) else {
                    throw error
                }
                currentRequest = next.request
                currentCandidate = next.candidate
            }
        }
    }

    static func sseLinesWithCustomThinkingAdaptation(
        _ request: URLRequest,
        baseBody: [String: Any],
        provider: LLMRemoteProvider,
        baseURL: URL,
        model: String,
        diagnosticsRecorder: LLMRequestDiagnosticsRecorder?,
        candidate: LLMThinkingTuningCandidate?
    ) async throws -> CustomThinkingStreamResult {
        var currentRequest = request
        var currentCandidate = candidate

        while true {
            do {
                let attemptID = diagnosticsRecorder?.beginAttempt(
                    provider: provider.rawValue,
                    endpoint: currentRequest.url ?? baseURL,
                    model: model
                ) ?? UUID()
                let lines = try await SSEClient.lines(
                    for: currentRequest,
                    diagnosticsRecorder: diagnosticsRecorder,
                    attemptID: attemptID
                )
                return CustomThinkingStreamResult(
                    lines: lines,
                    candidate: currentCandidate,
                    attemptID: attemptID
                )
            } catch {
                guard let next = try nextCustomThinkingRetry(
                    after: error,
                    provider: provider,
                    baseURL: baseURL,
                    failedCandidate: currentCandidate,
                    originalRequest: request,
                    baseBody: baseBody
                ) else {
                    throw error
                }
                currentRequest = next.request
                currentCandidate = next.candidate
            }
        }
    }

    static func applyCustomThinkingTuning(
        body: inout [String: Any],
        provider: LLMRemoteProvider,
        baseURL: URL
    ) -> LLMThinkingTuningCandidate? {
        guard provider == .custom else { return nil }
        return customThinkingTuningStore.applyCandidate(to: &body, for: baseURL)
    }

    static func recordCustomThinkingTuningSuccess(
        provider: LLMRemoteProvider,
        baseURL: URL,
        candidate: LLMThinkingTuningCandidate?,
        containsThinking: Bool
    ) {
        guard provider == .custom else { return }
        customThinkingTuningStore.recordSuccess(
            baseURL: baseURL,
            candidate: candidate,
            containsThinking: containsThinking
        )
    }

    private static func nextCustomThinkingRetry(
        after error: Error,
        provider: LLMRemoteProvider,
        baseURL: URL,
        failedCandidate: LLMThinkingTuningCandidate?,
        originalRequest: URLRequest,
        baseBody: [String: Any]
    ) throws -> (request: URLRequest, candidate: LLMThinkingTuningCandidate?)? {
        guard provider == .custom,
              OpenAICompatibleResponseSupport.shouldRetryWithoutCustomThinkingTuning(error: error)
        else {
            return nil
        }

        customThinkingTuningStore.recordUnsupportedParameter(
            baseURL: baseURL,
            candidate: failedCandidate
        )

        var nextBody = baseBody
        let nextCandidate = customThinkingTuningStore.applyCandidate(to: &nextBody, for: baseURL)

        if let nextCandidate {
            NetworkDebugLogger.logMessage(
                "Custom LLM rejected thinking tuning parameters; retrying with \(nextCandidate.id)."
            )
        } else {
            NetworkDebugLogger.logMessage(
                "Custom LLM rejected all thinking tuning candidates; retrying without tuning."
            )
        }

        var retryRequest = originalRequest
        retryRequest.httpBody = try JSONSerialization.data(withJSONObject: nextBody)
        return (retryRequest, nextCandidate)
    }
}

enum SSEClient {
    static func lines(
        for request: URLRequest,
        diagnosticsRecorder: LLMRequestDiagnosticsRecorder? = nil,
        attemptID: UUID = UUID()
    ) async throws -> AsyncThrowingStream<String, Error> {
        var instrumentedRequest = request
        if let diagnosticsRecorder {
            instrumentedRequest.setValue(
                attemptID.uuidString,
                forHTTPHeaderField: LLMURLSessionMetricsDelegate.diagnosticsHeader
            )
            LLMHTTPSession.metricsDelegate.register(id: attemptID, recorder: diagnosticsRecorder)
        }
        let (bytes, response) = try await LLMHTTPSession.shared.bytes(for: instrumentedRequest)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, bodyDescription: "<invalid non-http response>")
            throw NSError(domain: "SSE", code: 1)
        }

        diagnosticsRecorder?.markResponseHeaders(id: attemptID, statusCode: http.statusCode)

        if !(200 ..< 300).contains(http.statusCode) {
            var errorBodyData = Data()
            for try await byte in bytes {
                errorBodyData.append(byte)
            }
            NetworkDebugLogger.logResponse(http, data: errorBodyData)
            if let billingError = TypefluxCloudBillingError.fromHTTPStatus(http.statusCode, bodyData: errorBodyData) {
                throw billingError
            }
            let errorBody = String(data: errorBodyData, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "SSE",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"]
            )
        }

        NetworkDebugLogger.logResponse(http, bodyDescription: "<stream opened>")

        return lines(for: bytes, diagnosticsRecorder: diagnosticsRecorder, attemptID: attemptID)
    }

    static func lines(
        for bytes: URLSession.AsyncBytes,
        diagnosticsRecorder: LLMRequestDiagnosticsRecorder? = nil,
        attemptID: UUID = UUID()
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)

                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let parseStartedAt = Date()
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
                                diagnosticsRecorder?.recordSSEParsing(
                                    id: attemptID,
                                    duration: Date().timeIntervalSince(parseStartedAt),
                                    yieldedEvent: true
                                )
                                continuation.yield(payload)
                            } else {
                                diagnosticsRecorder?.recordSSEParsing(
                                    id: attemptID,
                                    duration: Date().timeIntervalSince(parseStartedAt),
                                    yieldedEvent: false
                                )
                            }
                        }
                    }

                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), line.hasPrefix("data:") {
                        let parseStartedAt = Date()
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        diagnosticsRecorder?.recordSSEParsing(
                            id: attemptID,
                            duration: Date().timeIntervalSince(parseStartedAt),
                            yieldedEvent: true
                        )
                        continuation.yield(payload)
                    }

                    diagnosticsRecorder?.markResponseCompleted(id: attemptID)
                    continuation.finish()
                } catch {
                    diagnosticsRecorder?.markResponseCompleted(id: attemptID)
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
