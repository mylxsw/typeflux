import Foundation
import Security

/// Secrets are stored separately from settings, scoped to provider and endpoint.
struct AskImageKeyStore {
    var read: (String) -> String
    var write: (String, String) throws -> Void

    static let live = AskImageKeyStore(read: { account in
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }, write: { account, key in
        let query = query(account)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AskImageError.keychain }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AskImageError.keychain }
        } else if status != errSecSuccess {
            throw AskImageError.keychain
        }
    })

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.typeflux.ask.image-generation",
         kSecAttrAccount as String: account]
    }
}

struct AskImageSettings {
    let defaults: UserDefaults
    var keys = AskImageKeyStore.live

    var enabled: Bool {
        get { defaults.bool(forKey: "ask.imageGeneration.enabled") }
        nonmutating set { defaults.set(newValue, forKey: "ask.imageGeneration.enabled") }
    }

    var provider: AskImageProvider {
        get { AskImageProvider(rawValue: defaults.string(forKey: "ask.imageGeneration.provider") ?? "") ?? .volcengine }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ask.imageGeneration.provider") }
    }

    func configuration(for provider: AskImageProvider) -> AskImageConfiguration {
        guard let data = defaults.data(forKey: "ask.imageGeneration." + provider.rawValue),
              let config = try? JSONDecoder().decode(AskImageConfiguration.self, from: data),
              config.provider == provider else { return .preset(provider) }
        return config
    }

    var configuration: AskImageConfiguration {
        configuration(for: provider)
    }

    static func credentialID(_ config: AskImageConfiguration) -> String {
        let endpoint = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return config.provider.rawValue + ":" + AskToolPolicy.digest(endpoint)
    }

    func key(for config: AskImageConfiguration) -> String {
        keys.read(Self.credentialID(config))
    }

    func save(_ config: AskImageConfiguration, key: String) throws {
        // Never persist the configuration as saved when the credential write failed.
        let data = try JSONEncoder().encode(config)
        try keys.write(Self.credentialID(config), key.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(data, forKey: "ask.imageGeneration." + config.provider.rawValue)
        provider = config.provider
    }

    var isReady: Bool {
        enabled && (try? configuration.validate(key: key(for: configuration))) != nil
    }
}
