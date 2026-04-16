import Foundation
import Security

struct GoogleCloudSpeechOAuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Int

    var isExpired: Bool {
        expiresAt <= Int(Date().timeIntervalSince1970)
    }

    var isExpiringSoon: Bool {
        expiresAt <= Int(Date().timeIntervalSince1970 + 300)
    }
}

struct GoogleCloudSpeechOAuthTokenStore {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "dev.typeflux").google-cloud-speech"
    private static let account = "oauth-token"

    static func save(_ token: GoogleCloudSpeechOAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load() -> GoogleCloudSpeechOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = try? JSONDecoder().decode(GoogleCloudSpeechOAuthToken.self, from: data)
        else {
            return nil
        }

        return token
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum GoogleCloudSpeechCredentialResolver {
    typealias TokenLoader = () -> GoogleCloudSpeechOAuthToken?
    typealias TokenSaver = (GoogleCloudSpeechOAuthToken) -> Void
    typealias TokenRefresher = (String, String, String?) async throws -> GoogleCloudSpeechOAuthToken

    static func isStoredAuthorizationAvailable() -> Bool {
        guard let token = GoogleCloudSpeechOAuthTokenStore.load() else {
            return false
        }

        if !token.accessToken.isEmpty, !token.isExpired {
            return true
        }

        if let refreshToken = token.refreshToken {
            return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return false
    }

    static func resolveCredential(
        manualCredential: String,
        clientID: String = AppServerConfiguration.googleOAuthClientID,
        clientSecret: String = AppServerConfiguration.googleOAuthClientSecret,
        tokenLoader: TokenLoader = GoogleCloudSpeechOAuthTokenStore.load,
        tokenSaver: TokenSaver = GoogleCloudSpeechOAuthTokenStore.save,
        tokenRefresher: TokenRefresher = GoogleOAuthService.refreshAccessToken,
    ) async throws -> String {
        let trimmedManualCredential = manualCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedManualCredential.isEmpty {
            return trimmedManualCredential
        }

        guard let storedToken = tokenLoader() else {
            throw GoogleCloudSpeechError.missingAPIKey
        }

        if !storedToken.accessToken.isEmpty, !storedToken.isExpiringSoon {
            return storedToken.accessToken
        }

        guard let refreshToken = storedToken.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GoogleCloudSpeechError.missingAPIKey
        }

        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshedToken = try await tokenRefresher(
            refreshToken,
            clientID,
            trimmedClientSecret.isEmpty ? nil : trimmedClientSecret,
        )
        tokenSaver(refreshedToken)
        return refreshedToken.accessToken
    }
}
