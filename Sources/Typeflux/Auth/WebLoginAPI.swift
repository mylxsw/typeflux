import Foundation

@MainActor
protocol WebLoginAPI {
    func create(proof: WebLoginProof) async throws -> WebLoginTransaction
    func exchange(code: String, verifier: String) async throws -> LoginResponse
}

/// A single pinned HTTP(S) endpoint, with no failover, redirects, cookies or application retries.
/// A lost token response must restart authorization, never replay a possibly consumed code.
final class WebLoginHTTPAPI: WebLoginAPI {
    private let configuration: WebLoginConfiguration
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private let session: URLSession?

    init(configuration: WebLoginConfiguration, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.configuration = configuration
        if let send {
            self.send = send
            session = nil
            return
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCache = nil
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: WebLoginNoRedirect(),
            delegateQueue: nil
        )
        self.session = session
        self.send = { try await session.data(for: $0) }
    }

    deinit { session?.invalidateAndCancel() }

    func create(proof: WebLoginProof) async throws -> WebLoginTransaction {
        try await post(path: "/api/v1/auth/app/transactions", body: [
            "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI,
            "state": proof.state, "code_challenge": proof.challenge, "code_challenge_method": "S256"
        ])
    }

    func exchange(code: String, verifier: String) async throws -> LoginResponse {
        try await post(path: "/api/v1/auth/app/token", body: [
            "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI,
            "code": code, "code_verifier": verifier
        ])
    }

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        guard WebLoginConfiguration.isWebOrigin(configuration.apiOrigin)
        else { throw WebLoginFailure.invalidResponse }
        var parts = URLComponents(url: configuration.apiOrigin, resolvingAgainstBaseURL: false)!
        parts.path = path
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw WebLoginFailure.invalidResponse }
        let envelope = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        guard (200 ..< 300).contains(http.statusCode), envelope.code == "OK", let result = envelope.data else {
            // Do not expose raw server bodies, grant codes or tokens to logs/UI.
            throw WebLoginFailure.restartRequired
        }
        return result
    }
}

final class WebLoginNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
