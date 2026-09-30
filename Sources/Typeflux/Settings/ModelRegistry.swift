import Foundation

/// A stable reference identifies a model independently of its endpoint and display name.
struct RegisteredModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var reference: String = "custom:" + UUID().uuidString.lowercased()
    var vision: Bool?
    var chat: Bool?
    var scenarios: [String]?
    var pricing: CloudModelPricing?
    var contextWindowTokens: Int?
    var maxOutputTokens: Int?
    var reasoning: Bool?

    var displayName: String {
        if let label = pricing?.label { return name + " · " + label }
        return name
    }


    var exclusionReason: String? {
        let value = id.lowercased()
        return chat == false || ["embedding", "whisper", "tts", "rerank", "moderation", "dall-e"]
            .contains(where: value.contains)
            ? L("models.notChat") : nil
    }
}

struct RegisteredProvider: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var remote: LLMRemoteProvider?
    var baseURL: String = ""
    var credentialAccount: String?
    var models: [RegisteredModel] = []
    var isOllama: Bool {
        id == "ollama"
    }

    var isCloud: Bool {
        remote == .typefluxCloud
    }
}

struct ModelRegistry: Codable, Equatable {
    static let storageKey = "models.registry.v2"
    var version = 2
    var providers: [RegisteredProvider] = []

    static func read(_ defaults: UserDefaults) -> ModelRegistry? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let registry = try? JSONDecoder().decode(Self.self, from: data), registry.version == 2 else { return nil }
        return registry
    }

    func write(_ defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    func resolve(_ reference: String) -> (RegisteredProvider, RegisteredModel)? {
        for provider in providers {
            if let model = provider.models.first(where: { $0.reference == reference }) {
                return (provider, model)
            }
        }
        return nil
    }

    /// Preserve custom profile identity and Keychain accounts; never merge endpoints by URL alone.
    static func migrate(settings: SettingsStore, profiles: [AskModelProfile]) -> Self {
        var result = Self()
        for remote in LLMRemoteProvider.settingsDisplayOrder {
            var provider = RegisteredProvider(id: remote.rawValue, name: remote.displayName, remote: remote)
            if remote == .typefluxCloud {
                provider.models = [.init(
                    id: "default",
                    name: "Typeflux Cloud",
                    reference: "cloud:default",
                    vision: true
                )]
            } else {
                let model = settings.llmModel(for: remote)
                let hasStoredModel = settings.defaults.string(forKey: "llm.remote.\(remote.rawValue).model") != nil
                if !model.isEmpty, hasStoredModel || !settings.llmAPIKey(for: remote).isEmpty ||
                    (settings.llmProvider == .openAICompatible && settings.llmRemoteProvider == remote) {
                    provider.models = [.init(id: model, name: model)]
                }
            }
            result.providers.append(provider)
        }
        let ollamaModels: [RegisteredModel] = settings.ollamaModel.isEmpty ? [] : [.init(
            id: settings.ollamaModel,
            name: settings.ollamaModel
        )]
        result.providers.append(.init(id: "ollama", name: "Ollama", models: ollamaModels))
        for profile in profiles {
            result.providers.append(.init(id: "endpoint:" + profile.id, name: profile.name, baseURL: profile.baseURL,
                                          credentialAccount: "ask-model-" + profile.id,
                                          models: [.init(
                                              id: profile.model,
                                              name: profile.model,
                                              reference: profile.reference
                                          )]))
        }
        return result
    }

    func legacyRewriteReference(settings: SettingsStore) -> String? {
        let id = settings.llmProvider == .ollama ? "ollama" : settings.llmRemoteProvider.rawValue
        let model = settings.llmProvider == .ollama ? settings.ollamaModel : settings.llmModel
        return providers.first(where: { $0.id == id })?.models
            .first(where: { $0.id == model || id == "typefluxCloud" })?.reference
    }
}

extension RegisteredProvider {
    func connection(settings: SettingsStore, model: RegisteredModel) -> SettingsStore.TextLLMConfiguration {
        if let remote {
            if remote == .freeModel, let free = FreeLLMModelRegistry.resolve(modelName: model.id) {
                return .init(provider: .freeModel, baseURL: free.baseURL, model: free.modelName, apiKey: free.apiKey)
            }
            return .init(
                provider: remote,
                baseURL: settings.llmBaseURL(for: remote),
                model: remote == .typefluxCloud && model.id != "default" ? model.reference : model.id,
                apiKey: settings.llmAPIKey(for: remote)
            )
        }
        if isOllama {
            return .init(provider: .custom, baseURL: settings.ollamaBaseURL, model: model.id, apiKey: "")
        }
        return .init(provider: .custom, baseURL: baseURL, model: model.id,
                     apiKey: credentialAccount.flatMap { KeychainTokenStore.getKeychainValue(account: $0) } ?? "")
    }
}
