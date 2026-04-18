import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os

/// Handles the GitHub OAuth 2.0 + PKCE flow using ASWebAuthenticationSession.
///
/// Flow:
/// 1. Opens GitHub's OAuth authorization page in a secure browser session.
/// 2. User signs in and grants consent.
/// 3. GitHub redirects back with an authorization code.
/// 4. The authorization code and PKCE verifier are returned to the Typeflux backend.
/// 5. The backend exchanges the code for tokens using the GitHub OAuth app secret.
///
/// Configuration:
/// - Set `GITHUB_OAUTH_CLIENT_ID` in the environment (or via AppServerConfiguration)
///   to a GitHub OAuth App client ID from https://github.com/settings/developers.
/// - Register `dev.typeflux://oauth/github` as an authorized callback URL in your GitHub OAuth App.
@MainActor
struct GitHubOAuthService {
    private static let logger = Logger(subsystem: "dev.typeflux", category: "GitHubOAuthService")

    private static let redirectURI = "dev.typeflux://oauth/github"
    private static let callbackScheme = "dev.typeflux"

    struct AuthorizationCode {
        let code: String
        let codeVerifier: String
    }

    /// Initiates the GitHub sign-in flow and returns the authorization code plus PKCE verifier.
    ///
    /// - Parameters:
    ///   - clientID: GitHub OAuth App client ID.
    static func signIn(clientID: String) async throws -> AuthorizationCode {
        let (codeVerifier, codeChallenge) = makePKCE()
        let state = UUID().uuidString

        let url = makeAuthorizationURL(
            clientID: clientID,
            state: state,
            codeChallenge: codeChallenge
        )

        logger.debug("[GitHub OAuth] auth URL: \(url.absoluteString, privacy: .public)")
        let code = try await openAuthSession(url: url, expectedState: state)
        logger.debug("[GitHub OAuth] received code (first 12 chars): \(String(code.prefix(12)), privacy: .public)...")
        return AuthorizationCode(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - Private

    static func makeAuthorizationURL(
        clientID: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "read:user user:email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    private static func openAuthSession(url: URL, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
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
                    continuation.resume(throwing: GitHubAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = GitHubAuthSessionContextProvider.shared
            session.start()
        }
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

enum GitHubAuthError: LocalizedError {
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "GitHub sign-in was cancelled or returned an invalid response."
        }
    }
}

// MARK: - Presentation Context

private final class GitHubAuthSessionContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GitHubAuthSessionContextProvider()

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
