import Foundation
import Security

/// Web search configuration for local Ask: the user's own search account.
/// UserDefaults and Keychain support concurrent access; each request pins its provider.
struct AskSearchSettings: @unchecked Sendable {
    enum Provider: String, CaseIterable, Sendable { case none, tavily, brave, cloudflare }

    var defaults: UserDefaults
    var keychainService = "com.typeflux.ask.search"

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "ask.search.provider") ?? "") ?? .none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ask.search.provider") }
    }

    private func query(for provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: provider == .cloudflare ? "cloudflare-token" : "api-key"]
    }

    var apiKey: String { apiKey(for: provider) }

    private func apiKey(for provider: Provider) -> String {
        var item: CFTypeRef?
        var request = query(for: provider)
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func setAPIKey(_ key: String) {
        let query = query(for: provider)
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    var cloudflare: AskCloudflareSearchConfiguration {
        get {
            AskCloudflareSearchConfiguration(
                accountID: defaults.string(forKey: "ask.search.cloudflare.accountID") ?? "",
                gatewayID: defaults.string(forKey: "ask.search.cloudflare.gatewayID") ?? "default",
                provider: defaults.string(forKey: "ask.search.cloudflare.provider") ?? "ceramic",
                byokAlias: defaults.string(forKey: "ask.search.cloudflare.byokAlias") ?? ""
            )
        }
        nonmutating set {
            defaults.set(newValue.accountID, forKey: "ask.search.cloudflare.accountID")
            defaults.set(newValue.gatewayID, forKey: "ask.search.cloudflare.gatewayID")
            defaults.set(newValue.provider, forKey: "ask.search.cloudflare.provider")
            defaults.set(newValue.byokAlias, forKey: "ask.search.cloudflare.byokAlias")
        }
    }

    var configuration: AskSearchConfiguration {
        let selected = provider
        return .init(provider: selected, apiKey: apiKey(for: selected), cloudflare: cloudflare)
    }
    var isConfigured: Bool { configuration.isConfigured }
}
