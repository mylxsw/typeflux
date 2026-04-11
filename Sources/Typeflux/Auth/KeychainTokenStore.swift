import Foundation
import Security

/// Stores authentication tokens in the macOS Keychain.
struct KeychainTokenStore {
    private struct StoredToken: Codable {
        let token: String
        let expiresAt: Int
        let refreshToken: String?
    }

    private static let service = "\(Bundle.main.bundleIdentifier ?? "dev.typeflux").auth"
    private static let tokenAccount = "session"
    private static let userProfileAccount = "userProfile"

    // MARK: - Token

    static func saveToken(_ token: String, expiresAt: Int, refreshToken: String? = nil) {
        let storedToken = StoredToken(token: token, expiresAt: expiresAt, refreshToken: refreshToken)
        setKeychainValue(storedToken, account: tokenAccount)
    }

    static func loadToken() -> (token: String, expiresAt: Int)? {
        guard let storedToken: StoredToken = getKeychainValue(account: tokenAccount) else {
            return nil
        }
        return (storedToken.token, storedToken.expiresAt)
    }

    static func loadRefreshToken() -> String? {
        let stored: StoredToken? = getKeychainValue(account: tokenAccount)
        return stored?.refreshToken
    }

    static func deleteToken() {
        deleteKeychainItem(account: tokenAccount)
    }

    static var isTokenValid: Bool {
        guard let stored = loadToken() else { return false }
        return stored.expiresAt > Int(Date().timeIntervalSince1970)
    }

    /// Returns true if the access token will expire within the given interval.
    static func isTokenExpiringSoon(within interval: TimeInterval = 7 * 24 * 3600) -> Bool {
        guard let stored = loadToken() else { return true }
        let threshold = Int(Date().timeIntervalSince1970 + interval)
        return stored.expiresAt < threshold
    }

    // MARK: - User Profile

    static func saveUserProfile(_ profile: UserProfile) {
        setKeychainValue(profile, account: userProfileAccount)
    }

    static func loadUserProfile() -> UserProfile? {
        getKeychainValue(account: userProfileAccount)
    }

    static func deleteUserProfile() {
        deleteKeychainItem(account: userProfileAccount)
    }

    // MARK: - Clear All

    static func clearAll() {
        deleteToken()
        deleteUserProfile()
    }

    // MARK: - Keychain Helpers

    private static func setKeychainValue<Value: Encodable>(_ value: Value, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func getKeychainValue<Value: Decodable>(account: String) -> Value? {
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
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        return value
    }

    private static func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
