import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

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
/// - Register the redirect URI `typeflux-auth://oauth-callback/google` in the
///   Google Cloud Console for that client ID.
@MainActor
struct GoogleOAuthService {
    private static let callbackScheme = "typeflux-auth"
    private static let redirectURI = "typeflux-auth://oauth-callback/google"

    /// Initiates the Google sign-in flow and returns a Google ID token on success.
    static func signIn(clientID: String) async throws -> String {
        let (codeVerifier, codeChallenge) = makePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        let code = try await openAuthSession(url: components.url!, expectedState: state)
        return try await exchangeCodeForIDToken(code: code, codeVerifier: codeVerifier, clientID: clientID)
    }

    // MARK: - Private

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

    private static func exchangeCodeForIDToken(
        code: String,
        codeVerifier: String,
        clientID: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let params: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let idToken: String?
            let error: String?
            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case error
            }
        }

        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let errorDescription = response.error {
            throw GoogleAuthError.tokenExchangeFailed(errorDescription)
        }
        guard let idToken = response.idToken else {
            throw GoogleAuthError.missingIDToken
        }
        return idToken
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
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Google sign-in was cancelled or returned an invalid response."
        case .missingIDToken:
            "Failed to retrieve Google ID token."
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
