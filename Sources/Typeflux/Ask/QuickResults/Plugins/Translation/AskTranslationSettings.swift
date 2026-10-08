import Foundation

/// Translation services the plugin can send text to, once the user adds their keys.
enum AskTranslationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepl, google, microsoft, youdao, baidu, tencent, volcengine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepl: "DeepL"
        case .google: "Google"
        case .microsoft: "Microsoft"
        case .youdao: L("ask.translation.provider.youdao")
        case .baidu: L("ask.translation.provider.baidu")
        case .tencent: L("ask.translation.provider.tencent")
        case .volcengine: L("ask.translation.provider.volcengine")
        }
    }

    /// What each credential field holds for this service; nil hides the field.
    var keyLabel: String {
        switch self {
        case .deepl: "Auth Key"
        case .google, .microsoft: "API Key"
        case .youdao: L("ask.translation.field.appKey")
        case .baidu: "APP ID"
        case .tencent: "SecretId"
        case .volcengine: "Access Key ID"
        }
    }

    var secretLabel: String? {
        switch self {
        case .deepl, .google, .microsoft: nil
        case .youdao: L("ask.translation.field.appSecret")
        case .baidu: L("ask.translation.field.secret")
        case .tencent: "SecretKey"
        case .volcengine: "Secret Access Key"
        }
    }

    var regionLabel: String? {
        switch self {
        case .tencent, .volcengine: L("ask.translation.field.region")
        case .microsoft: L("ask.translation.field.regionOptional")
        default: nil
        }
    }

    /// The region used when the user leaves it empty.
    var defaultRegion: String {
        switch self {
        case .tencent: "ap-guangzhou"
        case .volcengine: "cn-north-1"
        default: ""
        }
    }
}

/// The keys for one service. Kept in the Keychain, never in UserDefaults.
struct AskTranslationCredentials: Codable, Equatable, Sendable {
    var key = ""
    var secret = ""
    var region = ""

    func trimmed() -> Self {
        .init(key: key.trimmingCharacters(in: .whitespacesAndNewlines),
              secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
              region: region.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether `provider` has every field it needs.
    func isComplete(for provider: AskTranslationProvider) -> Bool {
        let value = trimmed()
        return !value.key.isEmpty && (provider.secretLabel == nil || !value.secret.isEmpty)
            && ![value.key, value.secret, value.region].contains { $0.contains(where: \.isNewline) }
    }

    func region(for provider: AskTranslationProvider) -> String {
        let region = trimmed().region
        return region.isEmpty ? provider.defaultRegion : region
    }
}

/// Where services' keys live.
protocol AskTranslationCredentialStoring: Sendable {
    func credentials(for provider: AskTranslationProvider) -> AskTranslationCredentials?
    func save(_ credentials: AskTranslationCredentials, for provider: AskTranslationProvider) -> Bool
    func remove(_ provider: AskTranslationProvider)
}

struct AskKeychainTranslationCredentials: AskTranslationCredentialStoring {
    static func account(_ provider: AskTranslationProvider) -> String { "translation-provider-" + provider.rawValue }

    func credentials(for provider: AskTranslationProvider) -> AskTranslationCredentials? {
        KeychainTokenStore.getKeychainValue(account: Self.account(provider))
    }

    func save(_ credentials: AskTranslationCredentials, for provider: AskTranslationProvider) -> Bool {
        KeychainTokenStore.setKeychainValue(credentials.trimmed(), account: Self.account(provider))
    }

    func remove(_ provider: AskTranslationProvider) {
        KeychainTokenStore.deleteKeychainItem(account: Self.account(provider))
    }
}

/// The engine translations use when this Mac cannot translate the pair.
enum AskTranslationEngineChoice: Hashable, Sendable {
    case ai
    case service(AskTranslationProvider)

    init(rawValue: String) {
        self = AskTranslationProvider(rawValue: rawValue).map(Self.service) ?? .ai
    }

    var rawValue: String {
        switch self {
        case .ai: "ai"
        case let .service(provider): provider.rawValue
        }
    }

    var provider: AskTranslationProvider? {
        if case let .service(provider) = self { return provider }
        return nil
    }
}

/// How the translation plugin picks its engine. The defaults are the plugin's
/// behaviour before it could be configured: this Mac first, then the AI with
/// the text-processing model.
struct AskTranslationSettings: Codable, Equatable, Sendable {
    var engine: AskTranslationEngineChoice = .ai
    /// A model in Settings → Models; empty follows the text-processing model.
    var modelReference = ""
    var prefersOnDevice = true
    /// A service that fails (keys, quota, network, language) hands the text to the AI.
    var fallsBackToAI = true

    init(engine: AskTranslationEngineChoice = .ai, modelReference: String = "", prefersOnDevice: Bool = true,
         fallsBackToAI: Bool = true) {
        self.engine = engine
        self.modelReference = modelReference
        self.prefersOnDevice = prefersOnDevice
        self.fallsBackToAI = fallsBackToAI
    }

    private enum CodingKeys: String, CodingKey { case engine, modelReference, prefersOnDevice, fallsBackToAI }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = AskTranslationEngineChoice(rawValue: try container.decodeIfPresent(String.self, forKey: .engine) ?? "ai")
        modelReference = try container.decodeIfPresent(String.self, forKey: .modelReference) ?? ""
        prefersOnDevice = try container.decodeIfPresent(Bool.self, forKey: .prefersOnDevice) ?? true
        fallsBackToAI = try container.decodeIfPresent(Bool.self, forKey: .fallsBackToAI) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engine.rawValue, forKey: .engine)
        try container.encode(modelReference, forKey: .modelReference)
        try container.encode(prefersOnDevice, forKey: .prefersOnDevice)
        try container.encode(fallsBackToAI, forKey: .fallsBackToAI)
    }
}

extension SettingsStore {
    static let askTranslationSettingsKey = "ask.translation.settings.v1"

    var askTranslationSettings: AskTranslationSettings {
        get {
            defaults.data(forKey: Self.askTranslationSettingsKey)
                .flatMap { try? JSONDecoder().decode(AskTranslationSettings.self, from: $0) } ?? AskTranslationSettings()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.askTranslationSettingsKey) }
        }
    }

    /// The model AI translations and word cards use: the one chosen for translation,
    /// or the text-processing model. A chosen model that was removed stays unavailable
    /// rather than quietly switching to another one.
    func translationLLMConfiguration() -> TextLLMConfiguration {
        let reference = askTranslationSettings.modelReference
        guard !reference.isEmpty else { return textLLMConfiguration() }
        if let (provider, model) = ModelRegistry.read(defaults)?.resolve(reference) {
            let configuration = provider.connection(settings: self, model: model)
            guard provider.isOllama else { return configuration }
            // Ollama answers OpenAI-style requests under /v1.
            return TextLLMConfiguration(provider: configuration.provider,
                                        baseURL: Self.ollamaOpenAIBaseURL(configuration.baseURL),
                                        model: configuration.model, apiKey: configuration.apiKey,
                                        apiStyle: configuration.apiStyle)
        }
        return TextLLMConfiguration(provider: .custom, baseURL: "", model: "", apiKey: "")
    }

    static func ollamaOpenAIBaseURL(_ baseURL: String) -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "http://127.0.0.1:11434" }
        while base.hasSuffix("/") { base.removeLast() }
        return base.lowercased().hasSuffix("/v1") ? base : base + "/v1"
    }
}
