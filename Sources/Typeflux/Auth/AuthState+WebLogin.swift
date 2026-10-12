import Foundation

@MainActor
extension AuthState {
    func makeWebLoginCoordinator(configuration: WebLoginConfiguration = .current) -> WebLoginCoordinator {
        WebLoginCoordinator(
            configuration: configuration, api: WebLoginHTTPAPI(configuration: configuration),
            store: WebLoginMemoryStore(),
            browserFactory: { WebLoginBrowser(url: $0, scheme: $1, completion: $2) },
            authGeneration: { [weak self] in self?.sessionGeneration ?? -1 },
            accept: { [weak self] response, generation in
                guard let self else { throw WebLoginFailure.restartRequired }
                try await acceptWebLogin(response, generation: generation)
            }
        )
    }

    func acceptWebLogin(_ response: LoginResponse, generation: Int,
                        persist: (String, Int, String?) -> Bool = { KeychainTokenStore.saveToken(
                            $0,
                            expiresAt: $1,
                            refreshToken: $2
                        ) }) async throws {
        guard generation == sessionGeneration else { throw WebLoginFailure.restartRequired }
        guard persist(response.accessToken, response.expiresAt, response.refreshToken) else {
            throw WebLoginFailure.storageFailed
        }
        await handleLoginSuccess(
            token: response.accessToken,
            expiresAt: response.expiresAt,
            refreshToken: response.refreshToken,
            sessionAlreadyPersisted: true
        )
    }
}
