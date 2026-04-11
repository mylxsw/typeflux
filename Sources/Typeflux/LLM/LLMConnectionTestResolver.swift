import Foundation

enum LLMConnectionTestResolver {
    static func resolve(
        provider: LLMRemoteProvider,
        baseURL: String,
        model: String,
        apiKey: String,
    ) async throws -> ResolvedLLMConnection {
        if provider == .typefluxCloud {
            let token = await MainActor.run { AuthState.shared.accessToken }
            guard let token else {
                throw TypefluxCloudLLMError.notLoggedIn
            }
            return try LLMConnectionResolver.resolve(
                provider: provider,
                baseURL: "",
                model: model,
                apiKey: token,
            )
        }

        return try LLMConnectionResolver.resolve(
            provider: provider,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
        )
    }
}
