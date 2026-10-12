import CryptoKit
import Foundation
import Security

struct WebLoginConfiguration {
    let enabled: Bool
    let clientID: String
    let redirectURI: String
    let websiteOrigin: URL
    let apiOrigin: URL

    static func resolve(environment: [String: String], info: [String: Any]) -> Self {
        func value(_ key: String, _ fallback: String) -> String {
            environment[key] ?? info[key] as? String ?? fallback
        }
        let development = value("TYPEFLUX_WEB_AUTH_CHANNEL", "production") == "development"
        return Self(
            enabled: value("TYPEFLUX_WEB_AUTH_ENABLED", "false") == "true",
            clientID: development ? "typeflux-macos-dev" : "typeflux-macos",
            redirectURI: development ? "ai.gulu.app.typeflux.dev://auth/callback" :
                "ai.gulu.app.typeflux://auth/callback",
            websiteOrigin: URL(string: value("TYPEFLUX_WEB_AUTH_ORIGIN", "https://typeflux.app")) ??
                URL(fileURLWithPath: "/"),
            apiOrigin: URL(string: value("TYPEFLUX_WEB_AUTH_API_ORIGIN", AppServerConfiguration.apiBaseURL)) ??
                URL(fileURLWithPath: "/")
        )
    }

    static var current: Self {
        resolve(environment: ProcessInfo.processInfo.environment, info: Bundle.main.infoDictionary ?? [:])
    }

    static func isHTTPSOrigin(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host?.isEmpty == false && parts.user == nil
            && parts.password == nil && parts.query == nil && parts.fragment == nil
            && (parts.path.isEmpty || parts.path == "/")
    }

    func matchesCallback(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI) else { return false }
        return parts.scheme == expected.scheme && parts.host == expected.host
            && parts.percentEncodedPath == expected.percentEncodedPath && parts.port == nil
            && parts.user == nil && parts.password == nil && parts.fragment == nil
    }

    func validate(_ transaction: WebLoginTransaction, now: Date) throws -> URL {
        guard Self.isHTTPSOrigin(websiteOrigin), Self.isHTTPSOrigin(apiOrigin),
              transaction.expiresAt > now.timeIntervalSince1970,
              transaction.expiresAt <= now.timeIntervalSince1970 + 1800,
              WebLoginProof.isOpaqueValue(transaction.transactionID),
              let url = URL(string: transaction.loginURL),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == websiteOrigin.scheme, parts.host == websiteOrigin.host,
              (parts.port ?? 443) == (websiteOrigin.port ?? 443),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/login",
              parts.queryItems == [URLQueryItem(name: "transaction", value: transaction.transactionID)]
        else { throw WebLoginFailure.invalidResponse }
        return url
    }
}

struct WebLoginProof {
    let state: String
    let verifier: String
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generate(random: (Int) throws -> Data = secureRandom) throws -> Self {
        let state = try random(32)
        let verifier = try random(32)
        guard state.count == 32, verifier.count == 32 else { throw WebLoginFailure.invalidResponse }
        return Self(state: base64URL(state), verifier: base64URL(verifier))
    }

    private static func secureRandom(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw WebLoginFailure.invalidResponse
        }
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func isOpaqueValue(_ value: String) -> Bool {
        value.count == 43 && value.utf8.allSatisfy {
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct WebLoginTransaction: Decodable {
    let transactionID: String
    let loginURL: String
    let expiresAt: TimeInterval
    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id", loginURL = "login_url", expiresAt = "expires_at"
    }
}

struct PendingWebLogin {
    let proof: WebLoginProof
    let transaction: WebLoginTransaction

    func code(from url: URL, configuration: WebLoginConfiguration, now: Date) throws -> String {
        guard transaction.expiresAt > now.timeIntervalSince1970 else { throw WebLoginFailure.expired }
        guard configuration.matchesCallback(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == proof.state,
              let code = items.first(where: { $0.name == "code" })?.value,
              WebLoginProof.isOpaqueValue(code)
        else { throw WebLoginFailure.invalidCallback }
        return code
    }
}

enum WebLoginFailure: Error, Equatable {
    case invalidResponse, invalidCallback, expired, browserUnavailable, restartRequired, storageFailed
    var localizationKey: String {
        switch self {
        case .expired: "auth.web.expired"
        case .browserUnavailable: "auth.web.browserUnavailable"
        case .storageFailed: "auth.web.storageFailed"
        case .invalidResponse, .invalidCallback, .restartRequired: "auth.web.restartRequired"
        }
    }
}
