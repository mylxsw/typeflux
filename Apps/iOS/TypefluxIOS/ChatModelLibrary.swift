import Foundation
import Observation
import Security
import TypefluxChat

/// The user's own providers and the default model for new conversations. Provider
/// settings live in UserDefaults; keys live in the Keychain, on this device only.
@MainActor @Observable
final class ChatModelLibrary {
    static let providersKey = "providers.v1"
    static let defaultModelKey = "ask.model.default"

    private let defaults: UserDefaults
    private let keys: any ChatProviderKeyStore
    private(set) var providers: [ChatProvider]

    /// The model new conversations start with. Nil follows the Typeflux Cloud catalog order.
    var defaultModelRef: String? {
        didSet {
            if defaultModelRef != oldValue {
                defaults.set(defaultModelRef, forKey: Self.defaultModelKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard, keys: any ChatProviderKeyStore = KeychainProviderKeyStore()) {
        self.defaults = defaults
        self.keys = keys
        providers = defaults.data(forKey: Self.providersKey)
            .flatMap { try? JSONDecoder().decode([ChatProvider].self, from: $0) } ?? []
        defaultModelRef = defaults.string(forKey: Self.defaultModelKey)
    }

    /// Nothing is written to the real defaults domain or Keychain.
    static func ephemeral() -> ChatModelLibrary {
        let suite = "app.typeflux.ios.ephemeral." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return ChatModelLibrary(defaults: defaults, keys: MemoryProviderKeyStore())
    }

    /// Enabled models of every provider, in provider order.
    var models: [ChatModel] {
        providers.flatMap(\.chatModels)
    }

    func provider(id: String) -> ChatProvider? {
        providers.first { $0.id == id }
    }

    func resolve(_ reference: String) -> (provider: ChatProvider, model: ChatProviderModel)? {
        guard let parts = ChatProvider.parse(reference: reference), let provider = provider(id: parts.provider),
              let model = provider.models.first(where: { $0.id == parts.model && $0.enabled }) else { return nil }
        return (provider, model)
    }

    func key(for providerID: String) -> String? {
        try? keys.load(id: providerID)
    }

    /// Saves a provider. A nil key keeps the stored one; an empty key removes it.
    func save(_ provider: ChatProvider, key: String?) throws {
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try keys.delete(id: provider.id)
            } else {
                try keys.save(trimmed, id: provider.id)
            }
        }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        persist()
    }

    /// Removes a provider and its key. Conversations that used it stay on the device.
    func delete(providerID: String) throws {
        try keys.delete(id: providerID)
        providers.removeAll { $0.id == providerID }
        if let reference = defaultModelRef, ChatProvider.parse(reference: reference)?.provider == providerID {
            defaultModelRef = nil
        }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(providers), forKey: Self.providersKey)
    }
}

@MainActor
protocol ChatProviderKeyStore {
    func load(id: String) throws -> String?
    func save(_ key: String, id: String) throws
    func delete(id: String) throws
}

final class MemoryProviderKeyStore: ChatProviderKeyStore {
    private var values: [String: String] = [:]

    func load(id: String) throws -> String? { values[id] }
    func save(_ key: String, id: String) throws { values[id] = key }
    func delete(id: String) throws { values[id] = nil }
}

/// One generic password per provider. Keys never leave the device: they are not
/// synchronized and not included in backups.
struct KeychainProviderKeyStore: ChatProviderKeyStore {
    var service = "app.typeflux.ios.provider-key"

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    func load(id: String) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainCredentialStore.StorageError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String, id: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainCredentialStore.StorageError(status: status) }
    }

    func delete(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStore.StorageError(status: status)
        }
    }
}
