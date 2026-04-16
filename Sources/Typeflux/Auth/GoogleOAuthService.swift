import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os

/// Handles the Google OAuth 2.0 + PKCE flow using ASWebAuthenticationSession.
///
/// Flow:
/// 1. Opens Google's OAuth authorization page in a secure browser session.
/// 2. User signs in and grants consent.
/// 3. Google redirects back with an authorization code.
/// 4. The code is exchanged for tokens at Google's token endpoint.
/// 5. The resulting ID token is returned for verification by the Typeflux backend.
///
/// Configuration:
/// - Set `GOOGLE_OAUTH_CLIENT_ID` in the environment (or via AppServerConfiguration)
///   to a Desktop-type OAuth 2.0 client ID from Google Cloud Console.
/// - No redirect URI registration is needed in Google Cloud Console — Desktop app
///   clients automatically allow the reverse-client-ID scheme redirect.
@MainActor
struct GoogleOAuthService {
    private static let logger = Logger(subsystem: "dev.typeflux", category: "GoogleOAuthService")
    private struct AuthorizationRequest {
        let url: URL
        let callbackScheme: String
        let state: String
        let codeVerifier: String
    }

    private struct TokenExchangeResponse: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let idToken: String?
        let refreshToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case error
            case errorDescription = "error_description"
        }
    }

    /// Initiates the Google sign-in flow and returns a Google ID token on success.
    ///
    /// - Parameters:
    ///   - clientID: Google OAuth 2.0 Client ID. Use an **iOS-type** client for best results
    ///     (no secret required). Desktop-type clients require `clientSecret`.
    ///   - clientSecret: Required only for Desktop-type OAuth clients. Leave nil for iOS-type clients.
    static func signIn(clientID: String, clientSecret: String? = nil) async throws -> String {
        let authorization = makeAuthorizationRequest(
            clientID: clientID,
            scopes: ["openid", "email", "profile"],
        )

        logger.debug("[Google OAuth] auth URL: \(authorization.url.absoluteString, privacy: .public)")
        let code = try await openAuthSession(
            url: authorization.url,
            scheme: authorization.callbackScheme,
            expectedState: authorization.state,
        )
        logger.debug("[Google OAuth] received code (first 12 chars): \(String(code.prefix(12)), privacy: .public)...")
        let response = try await exchangeAuthorizationCode(
            code: code,
            codeVerifier: authorization.codeVerifier,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: "\(authorization.callbackScheme):/"
        )
        guard let idToken = response.idToken else {
            throw GoogleAuthError.missingIDToken
        }
        return idToken
    }

    static func authorizeGoogleCloud(
        clientID: String,
        clientSecret: String? = nil
    ) async throws -> GoogleCloudSpeechOAuthToken {
        let authorization = makeAuthorizationRequest(
            clientID: clientID,
            scopes: ["https://www.googleapis.com/auth/cloud-platform"],
            accessType: "offline",
            prompt: "consent",
        )

        logger.debug("[Google OAuth] cloud-platform auth URL: \(authorization.url.absoluteString, privacy: .public)")
        let code = try await openAuthSession(
            url: authorization.url,
            scheme: authorization.callbackScheme,
            expectedState: authorization.state,
        )
        let response = try await exchangeAuthorizationCode(
            code: code,
            codeVerifier: authorization.codeVerifier,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: "\(authorization.callbackScheme):/",
        )
        guard let accessToken = response.accessToken,
              let expiresIn = response.expiresIn
        else {
            throw GoogleAuthError.missingAccessToken
        }

        return GoogleCloudSpeechOAuthToken(
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Int(Date().timeIntervalSince1970) + expiresIn,
        )
    }

    static func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String? = nil
    ) async throws -> GoogleCloudSpeechOAuthToken {
        var params: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }

        let response = try await tokenRequest(params: params)
        guard let accessToken = response.accessToken,
              let expiresIn = response.expiresIn
        else {
            throw GoogleAuthError.missingAccessToken
        }

        return GoogleCloudSpeechOAuthToken(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: Int(Date().timeIntervalSince1970) + expiresIn,
        )
    }

    // MARK: - Private

    private static func makeAuthorizationRequest(
        clientID: String,
        scopes: [String],
        accessType: String? = nil,
        prompt: String? = nil
    ) -> AuthorizationRequest {
        let scheme = reverseScheme(for: clientID)
        let redirectURI = "\(scheme):/"
        let (codeVerifier, codeChallenge) = makePKCE()
        let state = UUID().uuidString

        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let accessType {
            queryItems.append(URLQueryItem(name: "access_type", value: accessType))
        }
        if let prompt {
            queryItems.append(URLQueryItem(name: "prompt", value: prompt))
        }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = queryItems

        return AuthorizationRequest(
            url: components.url!,
            callbackScheme: scheme,
            state: state,
            codeVerifier: codeVerifier,
        )
    }

    /// Derives the reverse-DNS URL scheme from a Google client ID.
    ///
    /// Google Desktop app clients automatically accept redirects using the scheme
    /// derived by reversing the client ID domain components. For example:
    ///   `123456789-abc.apps.googleusercontent.com`
    ///   → `com.googleusercontent.apps.123456789-abc`
    ///
    /// No manual registration in Google Cloud Console is required.
    private static func reverseScheme(for clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        if clientID.hasSuffix(suffix) {
            let prefix = clientID.dropLast(suffix.count)
            return "com.googleusercontent.apps.\(prefix)"
        }
        // Fallback: reverse the dot-separated components
        return clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func openAuthSession(
        url: URL,
        scheme: String,
        expectedState: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let callbackURL,
                    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                    components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
                else {
                    continuation.resume(throwing: GoogleAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = AuthSessionContextProvider.shared
            session.start()
        }
    }

    private static func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        clientID: String,
        clientSecret: String?,
        redirectURI: String
    ) async throws -> TokenExchangeResponse {
        var params: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        if let secret = clientSecret, !secret.isEmpty {
            params["client_secret"] = secret
        }

        return try await tokenRequest(params: params)
    }

    private static func tokenRequest(params: [String: String]) async throws -> TokenExchangeResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let bodyString = params
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let redactedLogBody = bodyString
            .replacingOccurrences(of: #"client_secret=[^&]+"#, with: "client_secret=***", options: .regularExpression)
            .replacingOccurrences(of: #"refresh_token=[^&]+"#, with: "refresh_token=***", options: .regularExpression)
            .replacingOccurrences(of: #"code=[^&]+"#, with: "code=***", options: .regularExpression)
            .replacingOccurrences(of: #"access_token=[^&]+"#, with: "access_token=***", options: .regularExpression)
        logger.debug("[Google OAuth] token request body: \(redactedLogBody, privacy: .public)")

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? -1
        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let redactedResponse = rawResponse
            .replacingOccurrences(of: #""access_token"\s*:\s*"[^"]+""#, with: "\"access_token\":\"***\"", options: .regularExpression)
            .replacingOccurrences(of: #""refresh_token"\s*:\s*"[^"]+""#, with: "\"refresh_token\":\"***\"", options: .regularExpression)
            .replacingOccurrences(of: #""id_token"\s*:\s*"[^"]+""#, with: "\"id_token\":\"***\"", options: .regularExpression)
        logger.debug("[Google OAuth] token response [\(statusCode, privacy: .public)]: \(redactedResponse, privacy: .public)")

        let response = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        if let error = response.error {
            throw GoogleAuthError.tokenExchangeFailed(response.errorDescription ?? error)
        }
        return response
    }

    /// Percent-encodes a value for use in an application/x-www-form-urlencoded body.
    /// Uses only unreserved characters (RFC 3986) to avoid ambiguity — in particular,
    /// `+` is encoded as `%2B` rather than left as-is, which would be misread as a space.
    private static func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func makePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let challengeBytes = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(challengeBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }
}

// MARK: - Errors

enum GoogleAuthError: LocalizedError {
    case invalidCallback
    case missingIDToken
    case missingAccessToken
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Google sign-in was cancelled or returned an invalid response."
        case .missingIDToken:
            "Failed to retrieve Google ID token."
        case .missingAccessToken:
            "Failed to retrieve Google access token."
        case .tokenExchangeFailed(let reason):
            "Google token exchange failed: \(reason)"
        }
    }
}

// MARK: - Presentation Context

private final class AuthSessionContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthSessionContextProvider()

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
