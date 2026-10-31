import Foundation

enum OnboardingConnectionProbe {
    static func language(provider: RegisteredProvider,
                         configuration: SettingsStore.TextLLMConfiguration) async throws -> String {
        var baseURL = configuration.baseURL
        if provider.isOllama, !baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("/v1") {
            baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
        }
        let resolved = try await LLMConnectionTestResolver.resolve(provider: configuration.provider,
                                                                   baseURL: baseURL, model: configuration.model,
                                                                   apiKey: configuration.apiKey,
                                                                   apiStyle: configuration.effectiveAPIStyle)
        return try await RemoteLLMClient.previewConnection(provider: resolved.provider,
                                                           apiStyle: resolved.effectiveAPIStyle,
                                                           baseURL: resolved.baseURL, model: resolved.model,
                                                           apiKey: resolved.apiKey, additionalHeaders: resolved.headers(
                                                               for: .modelSetup,
                                                               feature: .textRewrite
                                                           ))
    }
}
