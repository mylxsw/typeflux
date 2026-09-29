import Combine
import Foundation

struct AskCloudModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var vision: Bool?
    var reference: String {
        "cloud:" + id
    }
}

struct AskModelProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var baseURL: String
    var model: String
    var reference: String {
        "custom:" + id
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw AskLocalError.message(L("ask.models.invalid"))
        }
    }
}

/// One catalog shared by settings, rewrite routing and conversation selection.
@MainActor
final class AskModelLibrary: ObservableObject {
    static let shared = AskModelLibrary()
    @Published private(set) var registry: ModelRegistry
    @Published var cloud: [AskCloudModel] = [.init(id: "default", name: "Typeflux Cloud")]
    @Published var defaultReference: String {
        didSet { defaults.set(defaultReference, forKey: "ask.model.default") }
    }

    @Published var rewriteReference: String {
        didSet { defaults.set(rewriteReference, forKey: "llm.profile.reference") }
    }

    @Published var catalogError: String?
    @Published var ollamaAvailable = false
    let automaticallyLoadsCatalog: Bool
    let defaults: UserDefaults
    let catalog: any ProviderModelCatalog
    private var loading = false
    var settings: SettingsStore {
        SettingsStore(defaults: defaults)
    }

    var providers: [RegisteredProvider] {
        registry.providers
    }

    var profiles: [AskModelProfile] {
        Self.readProfiles(defaults)
    }

    init(defaults: UserDefaults = .standard, automaticallyLoadsCatalog: Bool = true,
         catalog: any ProviderModelCatalog = HTTPProviderModelCatalog()) {
        self.defaults = defaults
        self.catalog = catalog
        self.automaticallyLoadsCatalog = automaticallyLoadsCatalog
        let store = SettingsStore(defaults: defaults)
        let existing = ModelRegistry.read(defaults)
        registry = existing ?? (defaults.data(forKey: ModelRegistry.storageKey) == nil
            ? ModelRegistry.migrate(settings: store, profiles: Self.readProfiles(defaults)) : ModelRegistry())
        defaultReference = defaults.string(forKey: "ask.model.default") ?? "cloud:default"
        rewriteReference = defaults.string(forKey: "llm.profile.reference") ?? ""
        if existing == nil, defaults.data(forKey: ModelRegistry.storageKey) == nil {
            do {
                try registry.write(defaults)
                if rewriteReference.isEmpty, defaults.object(forKey: "llm.provider") != nil,
                   let reference = registry.legacyRewriteReference(settings: store) {
                    rewriteReference = reference
                    defaults.set(reference, forKey: "llm.profile.reference")
                }
            } catch { catalogError = error.localizedDescription }
        } else if existing == nil {
            catalogError = L("models.corrupt")
        }
    }

    nonisolated static func readProfiles(_ defaults: UserDefaults) -> [AskModelProfile] {
        if let registry = ModelRegistry.read(defaults) {
            return registry.providers.filter { $0.id.hasPrefix("endpoint:") }.flatMap { provider in
                provider.models.map { model in
                    AskModelProfile(id: String(model.reference.dropFirst("custom:".count)), name: provider.name,
                                    baseURL: provider.baseURL, model: model.id)
                }
            }
        }
        guard let data = defaults.data(forKey: "llm.model.profiles") else { return [] }
        return (try? JSONDecoder().decode([AskModelProfile].self, from: data)) ?? []
    }

    nonisolated static func key(for profile: AskModelProfile) -> String {
        KeychainTokenStore.getKeychainValue(account: "ask-model-" + profile.id) ?? ""
    }

    /// Onboarding may choose its first provider after DI constructs the catalog.
    func adoptLegacySelectionIfNeeded() {
        guard rewriteReference.isEmpty, defaults.object(forKey: "llm.provider") != nil else { return }
        let store = settings
        let providerID = store.llmProvider == .ollama ? "ollama" : store.llmRemoteProvider.rawValue
        let modelID = store.llmProvider == .ollama ? store.ollamaModel : store.llmModel
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        do {
            if !provider.isCloud, !modelID.isEmpty {
                try addModels([.init(id: modelID, name: modelID)], providerID: providerID)
            }
            if let reference = registry.legacyRewriteReference(settings: store) {
                rewriteReference = reference
            }
        } catch { catalogError = error.localizedDescription }
    }

    func commit(_ next: ModelRegistry) throws {
        if defaults.data(forKey: ModelRegistry.storageKey) != nil, ModelRegistry.read(defaults) == nil {
            throw AskLocalError.message(L("models.corrupt"))
        }
        try next.write(defaults)
        registry = next
    }

    func save(_ profile: AskModelProfile, key: String) throws {
        try profile.validate()
        let account = "ask-model-" + profile.id
        guard KeychainTokenStore.setKeychainValue(key, account: account) else {
            throw AskLocalError.message(L("ask.models.keychainError"))
        }
        var next = registry
        let provider = RegisteredProvider(id: "endpoint:" + profile.id, name: profile.name, baseURL: profile.baseURL,
                                          credentialAccount: account, models: [.init(
                                              id: profile.model,
                                              name: profile.model,
                                              reference: profile.reference
                                          )])
        if let index = next.providers.firstIndex(where: { $0.id == provider.id }) {
            var updated = provider
            updated.models = next.providers[index].models
            if let modelIndex = updated.models.firstIndex(where: { $0.reference == profile.reference }) {
                updated.models[modelIndex].id = profile.model
                updated.models[modelIndex].name = profile.model
            }
            next.providers[index] = updated
        } else {
            next.providers.append(provider)
        }
        try commit(next)
    }

    var configuredProfile: AskModelProfile? {
        guard settings.llmProvider == .openAICompatible, settings.llmRemoteProvider != .typefluxCloud,
              settings.llmRemoteProvider.apiStyle == .openAICompatible else { return nil }
        let profile = AskModelProfile(name: settings.llmRemoteProvider.displayName + " · " + settings.llmModel,
                                      baseURL: settings.llmBaseURL, model: settings.llmModel)
        return (try? profile.validate()) == nil ? nil : profile
    }

    func importConfiguredProfile() throws {
        guard let profile = configuredProfile else { throw AskLocalError.message(L("ask.models.invalid")) }
        if profiles.contains(where: { $0.baseURL == profile.baseURL && $0.model == profile.model }) {
            return
        }
        try save(profile, key: settings.llmAPIKey)
    }

    func remove(_ profile: AskModelProfile) {
        guard let (provider, model) = registry.resolve(profile.reference) else { return }
        do { try removeModel(model.reference, providerID: provider.id) } catch {
            catalogError = error.localizedDescription
        }
    }

    func addModels(_ models: [RegisteredModel], providerID: String) throws {
        var next = registry
        guard let index = next.providers.firstIndex(where: { $0.id == providerID }) else { throw unavailable() }
        for var model in models {
            model.id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.id.isEmpty else { throw AskLocalError.message(L("ask.models.invalid")) }
            if !next.providers[index].models.contains(where: { $0.id == model.id }) {
                next.providers[index].models.append(model)
            }
        }
        try commit(next)
    }

    func removeModel(_ reference: String, providerID: String) throws {
        var next = registry
        guard let index = next.providers.firstIndex(where: { $0.id == providerID }) else { throw unavailable() }
        next.providers[index].models.removeAll { $0.reference == reference }
        // Keep both scene references and credentials. A deleted model never selects a replacement.
        try commit(next)
    }

    func updateConnection(_ provider: RegisteredProvider, baseURL: String, key: String) throws {
        if let remote = provider.remote {
            settings.setLLMBaseURL(baseURL, for: remote)
            settings.setLLMAPIKey(key, for: remote)
        } else if provider.isOllama {
            settings.ollamaBaseURL = baseURL
            ollamaAvailable = false
        } else {
            guard let account = provider.credentialAccount,
                  KeychainTokenStore.setKeychainValue(key, account: account) else {
                throw AskLocalError.message(L("ask.models.keychainError"))
            }
            var next = registry
            guard let index = next.providers.firstIndex(where: { $0.id == provider.id }) else { throw unavailable() }
            next.providers[index].baseURL = baseURL
            try commit(next)
        }
        objectWillChange.send()
    }

    func connection(_ provider: RegisteredProvider, model: RegisteredModel? = nil) -> SettingsStore
        .TextLLMConfiguration {
        provider.connection(settings: settings, model: model ?? provider.models.first ?? .init(id: "", name: ""))
    }

    func unavailableReason(_ provider: RegisteredProvider, loggedIn: Bool) -> String? {
        if provider.isCloud {
            return loggedIn ? nil : L("models.login")
        }
        if provider.isOllama && !ollamaAvailable {
            return L("models.ollamaMissing")
        }
        // Availability never needs a custom endpoint's secret. Keep Keychain reads
        // in actual requests and the connection editor, outside SwiftUI rendering.
        let baseURL: String = if let remote = provider.remote {
            settings.llmBaseURL(for: remote)
        } else {
            provider.isOllama ? settings.ollamaBaseURL : provider.baseURL
        }
        if baseURL.isEmpty {
            return L("models.endpointMissing")
        }
        if let remote = provider.remote, remote != .custom, remote != .freeModel,
           settings.llmAPIKey(for: remote).isEmpty {
            return L("models.keyMissing")
        }
        return provider.models.isEmpty ? L("models.noModels") : nil
    }

    func sortedProviders(loggedIn: Bool) -> [RegisteredProvider] {
        ModelAvailability.sorted(providers) { unavailableReason($0, loggedIn: loggedIn) == nil }
    }

    /// Picker contents, not the editable configuration catalog. Preserve stable references.
    func selectableProviders(loggedIn: Bool, hasImage: Bool) -> [RegisteredProvider] {
        providers.compactMap { provider in
            guard unavailableReason(provider, loggedIn: loggedIn) == nil else { return nil }
            var available = provider
            available.models = provider.models.filter {
                $0.exclusionReason == nil && (!hasImage || $0.vision == true)
            }
            return available.models.isEmpty ? nil : available
        }
    }

    func selectionReason(_ model: RegisteredModel, provider: RegisteredProvider, hasImage: Bool,
                         loggedIn: Bool) -> String? {
        if let reason = unavailableReason(provider, loggedIn: loggedIn) {
            return reason
        }
        if let reason = model.exclusionReason {
            return reason
        }
        if hasImage,
           model.vision != true {
            return L(model.vision == false ? "models.noVision" : "models.unknownVision")
        }
        return nil
    }

    func name(for reference: String) -> String {
        if let (provider, model) = registry
            .resolve(reference) {
            return provider.name == model.name ? model.name : provider.name + " · " + model.name
        }
        return L("ask.models.unavailable")
    }

    func unavailable() -> AskLocalError {
        .message(L("ask.models.unavailable"))
    }
}

extension AskModelLibrary {
    func loadModels(provider: RegisteredProvider) async throws -> [RegisteredModel] {
        if provider.isCloud {
            guard let token = AuthState.shared.accessToken else { throw AskLocalError.message(L("models.login")) }
            return try await AskAPIClient().models(token: token).map { .init(
                id: $0.id,
                name: $0.name,
                reference: $0.reference,
                vision: $0.vision ?? ($0.id == "default" ? true : nil)
            ) }
        }
        if provider
            .remote == .freeModel {
            return FreeLLMModelRegistry.suggestedModelNames.map { .init(id: $0, name: $0) }
        }
        return try await catalog.models(provider: provider, connection: connection(provider))
    }

    func probeOllama() async {
        guard let provider = providers.first(where: \.isOllama) else { return }
        do { _ = try await catalog.models(provider: provider, connection: connection(provider)); ollamaAvailable = true
        } catch { ollamaAvailable = false }
    }

    func refresh(api: any AskAPI = AskAPIClient(), token: String?) async {
        guard !loading, let token else { return }
        loading = true
        defer { loading = false }
        do {
            cloud = try await api.models(token: token)
            var next = registry
            if let index = next.providers.firstIndex(where: \.isCloud) {
                next.providers[index].models = next.providers[index].models.compactMap { existing in
                    guard let cloudModel = cloud.first(where: { $0.reference == existing.reference })
                    else { return nil }
                    var model = existing
                    model.name = cloudModel.name
                    if let vision = cloudModel.vision {
                        model.vision = vision
                    }
                    return model
                }
            }
            try commit(next)
            catalogError = nil
        } catch { catalogError = L("ask.models.catalogError") }
    }
}
