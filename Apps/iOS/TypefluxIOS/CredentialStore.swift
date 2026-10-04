import Foundation
import Security
import TypefluxChat

struct SavedAccount: Codable {
    let email: String
    let accessToken: String
    let expiresAt: Int
    let refreshToken: String?

    init(email: String, session: ChatSession) {
        self.email = email
        accessToken = session.accessToken
        expiresAt = session.expiresAt
        refreshToken = session.refreshToken
    }

    var session: ChatSession {
        ChatSession(accessToken: accessToken, expiresAt: expiresAt, refreshToken: refreshToken)
    }
}

@MainActor
protocol CredentialStore {
    func load() throws -> SavedAccount?
    func save(_ account: SavedAccount) throws
    func clear() throws
}

struct KeychainCredentialStore: CredentialStore {
    let service: String

    init(endpoint: URL) {
        service = "app.typeflux.ios.session." + endpoint.absoluteString
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "account"]
    }

    func load() throws -> SavedAccount? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageError(status: status) }
        return try JSONDecoder().decode(SavedAccount.self, from: data)
    }

    func save(_ account: SavedAccount) throws {
        let data = try JSONEncoder().encode(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
    }

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Unable to access the secure account storage (\(status))."
        }
    }
}

enum DeviceIdentity {
    static func persistentID(defaults: UserDefaults = .standard) -> String {
        let key = "typeflux.ios.device-id"
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
}
