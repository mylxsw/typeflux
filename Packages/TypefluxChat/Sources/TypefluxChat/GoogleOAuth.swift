import CryptoKit
import Foundation
import Security

/// A single, short-lived authorization attempt. No Google credentials are persisted.
public struct GoogleOAuthAuthorization: Sendable {
    public let clientID: String
    public let callbackScheme: String
    public let state: String
    public let verifier: String

    public init(clientID: String, state: String, verifier: String) throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        let prefix = String(clientID.dropLast(suffix.count))
        guard clientID.hasSuffix(suffix), !prefix.isEmpty,
              prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !state.isEmpty, (43 ... 128).contains(verifier.count),
              verifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else {
            throw GoogleOAuthError.notConfigured
        }
        self.clientID = clientID
        callbackScheme = "com.googleusercontent.apps." + prefix
        self.state = state
        self.verifier = verifier
    }

    public static func make(clientID: String) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleOAuthError.failed
        }
        return try Self(clientID: clientID, state: UUID().uuidString, verifier: base64URL(Data(bytes)))
    }

    public var redirectURI: String {
        callbackScheme + ":/"
    }

    public var url: URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        return components.url!
    }

    public func code(from callback: URL) throws -> String {
        guard callback.scheme == callbackScheme, callback.host == nil, callback.path == "/",
              callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GoogleOAuthError.invalidCallback
        }
        func matches(named name: String) -> [URLQueryItem] {
            items.filter { $0.name == name }
        }
        guard matches(named: "state").count == 1, matches(named: "state").first?.value == state else {
            throw GoogleOAuthError.invalidCallback
        }
        if matches(named: "error").count == 1, matches(named: "error").first?.value == "access_denied" {
            throw CancellationError()
        }
        guard matches(named: "error").isEmpty, matches(named: "code").count == 1,
              let code = matches(named: "code").first?.value, !code.isEmpty else {
            throw GoogleOAuthError.invalidCallback
        }
        return code
    }

    public func tokenRequest(code: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": clientID, "code": code, "code_verifier": verifier,
                      "redirect_uri": redirectURI, "grant_type": "authorization_code"]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return request
    }

    public func exchange(code: String, session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(for: tokenRequest(code: code))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GoogleOAuthError.failed }
        return try Self.identityToken(data: data, status: http.statusCode)
    }

    public static func identityToken(data: Data, status: Int) throws -> String {
        guard status == 200, let response = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data),
              let token = response.idToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleOAuthError.failed
        }
        return token
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum GoogleOAuthError: String, Error, LocalizedError, Sendable {
    case notConfigured = "Google sign-in is not configured."
    case invalidCallback = "Google sign-in returned an invalid response. Please try again."
    case failed = "Unable to sign in with Google. Please try again."

    public var errorDescription: String? {
        rawValue
    }
}

private struct GoogleTokenResponse: Decodable {
    let idToken: String?
    enum CodingKeys: String, CodingKey { case idToken = "id_token" }
}
