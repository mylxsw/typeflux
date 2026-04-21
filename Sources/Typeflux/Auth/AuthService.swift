import Foundation
import os

/// HTTP client for the Typeflux authentication API.
struct AuthAPIService {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "AuthAPIService")

    // MARK: - Public API

    static func enterEmail(_ email: String) async throws -> EnterEmailResponse {
        try await post(path: "/api/v1/auth/enter-email", body: EnterEmailRequest(email: email))
    }

    static func register(email: String, password: String, name: String?) async throws -> RegisterResponse {
        try await post(
            path: "/api/v1/auth/register",
            body: RegisterRequest(email: email, password: password, name: name),
        )
    }

    static func activate(email: String, code: String) async throws -> ActivateResponse {
        try await post(path: "/api/v1/auth/activate", body: ActivateRequest(email: email, code: code))
    }

    static func resendActivation(email: String, password: String) async throws -> ResendActivationResponse {
        try await post(
            path: "/api/v1/auth/resend-activation",
            body: ResendActivationRequest(email: email, password: password),
        )
    }

    static func login(email: String, password: String) async throws -> LoginResponse {
        try await post(path: "/api/v1/auth/login", body: LoginRequest(email: email, password: password))
    }

    static func forgotPassword(email: String) async throws -> ForgotPasswordResponse {
        try await post(path: "/api/v1/auth/forgot-password", body: ForgotPasswordRequest(email: email))
    }

    static func resetPassword(email: String, code: String, newPassword: String) async throws -> ResetPasswordResponse {
        try await post(
            path: "/api/v1/auth/reset-password",
            body: ResetPasswordRequest(email: email, code: code, newPassword: newPassword),
        )
    }

    static func changePassword(token: String, oldPassword: String, newPassword: String) async throws -> ChangePasswordResponse {
        try await post(
            path: "/api/v1/auth/change-password",
            body: ChangePasswordRequest(oldPassword: oldPassword, newPassword: newPassword),
            token: token,
        )
    }

    static func fetchProfile(token: String) async throws -> UserProfile {
        try await get(path: "/api/v1/me", token: token)
    }

    static func refreshToken(_ refreshToken: String) async throws -> LoginResponse {
        try await post(path: "/api/v1/auth/refresh", body: RefreshRequest(refreshToken: refreshToken))
    }

    static func logout(refreshToken: String) async throws {
        let _: LogoutResponse = try await post(path: "/api/v1/auth/logout", body: LogoutRequest(refreshToken: refreshToken))
    }

    static func loginWithGoogle(idToken: String) async throws -> LoginResponse {
        try await post(path: "/api/v1/auth/oauth/google", body: OAuthRequest(idToken: idToken))
    }

    static func loginWithApple(idToken: String) async throws -> LoginResponse {
        try await post(path: "/api/v1/auth/oauth/apple", body: OAuthRequest(idToken: idToken))
    }

    static func loginWithGitHub(code: String, codeVerifier: String) async throws -> LoginResponse {
        try await post(
            path: "/api/v1/auth/oauth/github",
            body: GitHubOAuthRequest(code: code, codeVerifier: codeVerifier)
        )
    }

    // MARK: - Networking Helpers

    private static func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        token: String? = nil,
    ) async throws -> Response {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw AuthError.networkError(error)
        }

        return try await execute(path: path, method: "POST", token: token, body: payload)
    }

    private static func get<Response: Decodable>(
        path: String,
        token: String? = nil,
    ) async throws -> Response {
        try await execute(path: path, method: "GET", token: token, body: nil)
    }

    private static func execute<Response: Decodable>(
        path: String,
        method: String,
        token: String?,
        body: Data?,
    ) async throws -> Response {
        let executor = CloudRequestExecutor()

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await executor.execute { baseURL in
                let url = AuthEndpointResolver.resolve(baseURL: baseURL, path: path)
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                if let body {
                    request.httpBody = body
                }
                request.timeoutInterval = 30
                return request
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch CloudRequestExecutorError.allEndpointsFailed(let lastError) {
            logger.error("All endpoints failed: \(lastError.localizedDescription)")
            throw AuthError.networkError(lastError)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw AuthError.networkError(error)
        }

        let envelope: APIResponse<Response>
        do {
            envelope = try JSONDecoder().decode(APIResponse<Response>.self, from: data)
        } catch {
            logger.error("Decoding error: \(error.localizedDescription)")
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            logger.error("[\(path, privacy: .public)] 401 body: \(raw, privacy: .public)")
            throw AuthError.unauthorized
        }

        guard httpResponse.statusCode >= 200, httpResponse.statusCode < 300,
              envelope.code == "OK",
              let responseData = envelope.data
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            logger.error("[\(path, privacy: .public)] \(httpResponse.statusCode, privacy: .public) body: \(raw, privacy: .public)")
            throw AuthError.serverError(
                code: envelope.code,
                message: envelope.message,
            )
        }

        return responseData
    }
}

/// Joins a Typeflux Cloud base URL with an API path, accommodating base URLs
/// that may or may not include a trailing slash.
enum AuthEndpointResolver {
    static func resolve(baseURL: URL, path: String) -> URL {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = "/" + trimmedPath
        } else {
            components.path = "/" + basePath + "/" + trimmedPath
        }
        if let url = components.url { return url }
        // Fall back to string concatenation if URLComponents can't reassemble
        // (extremely unlikely for valid HTTP base URLs).
        return URL(string: baseURL.absoluteString + path) ?? baseURL
    }
}
