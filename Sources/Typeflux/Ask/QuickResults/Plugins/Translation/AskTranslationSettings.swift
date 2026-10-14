import Foundation

/// Translation services the plugin can send text to, once the user adds their keys.
enum AskTranslationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepl, google, microsoft, youdao, baidu, tencent, volcengine

    var id: String { rawValue }

    static func configuredFallback(credentials: any AskTranslationCredentialStoring,
                                   preferred: Self? = nil) -> Self? {
        if let preferred, credentials.credentials(for: preferred)?.isComplete(for: preferred) == true {
            return preferred
        }
        return allCases.first { credentials.credentials(for: $0)?.isComplete(for: $0) == true }
    }

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

/// One independently enabled translation service. IDs survive model changes and reordering.
struct AskTranslationService: Codable, Equatable, Identifiable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case device
        // The service name is part of the v2 persistence contract.
        // swiftlint:disable:next identifier_name
        case ai(modelReference: String)
        case provider(AskTranslationProvider)
    }

    var id: String
    var kind: Kind
    var enabled: Bool

    static let device = Self(id: "device", kind: .device, enabled: true)
    static func ai(id: String = "ai.primary", modelReference: String = "", enabled: Bool = true) -> Self {
        Self(id: id, kind: .ai(modelReference: modelReference), enabled: enabled)
    }
    static func provider(_ provider: AskTranslationProvider, enabled: Bool = false) -> Self {
        Self(id: "provider." + provider.rawValue, kind: .provider(provider), enabled: enabled)
    }
    var isAI: Bool { if case .ai = kind { true } else { false } }
    var modelReference: String? { if case let .ai(reference) = kind { reference } else { nil } }
    var provider: AskTranslationProvider? { if case let .provider(provider) = kind { provider } else { nil } }
    var symbol: String {
        switch kind {
        case .device: "laptopcomputer"
        case .ai: "sparkle"
        case .provider: "character.bubble"
        }
    }
}

/// Ordered services and panel preferences shared with the launcher.
struct AskTranslationSettings: Codable, Equatable, Sendable {
    var services: [AskTranslationService]
    var panelPosition: AskTranslationPanelPosition = .center
    var maxHeight: AskTranslationPanelHeight = .eighty
    var autoCopy: AskTranslationAutoCopy = .none
    var keepState: AskTranslationKeepState = .minute

    init(services: [AskTranslationService]? = nil, modelReference: String = "") {
        self.services = services ?? [.device, .ai(modelReference: modelReference)]
            + AskTranslationProvider.allCases.map { .provider($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case services, panelPosition, maxHeight, autoCopy, keepState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        services = try container.decode([AskTranslationService].self, forKey: .services)
        panelPosition = try container.decodeIfPresent(AskTranslationPanelPosition.self, forKey: .panelPosition) ?? .center
        maxHeight = try container.decodeIfPresent(AskTranslationPanelHeight.self, forKey: .maxHeight) ?? .eighty
        autoCopy = try container.decodeIfPresent(AskTranslationAutoCopy.self, forKey: .autoCopy) ?? .none
        keepState = try container.decodeIfPresent(AskTranslationKeepState.self, forKey: .keepState) ?? .minute
    }

    var firstAI: AskTranslationService? { services.first(where: \.isAI) }
    var firstEnabledAI: AskTranslationService? { services.first { $0.isAI && $0.enabled } }
    /// Keep a model home even when the launcher has no checked AI services.
    var modelReference: String { (firstEnabledAI ?? firstAI)?.modelReference ?? "" }

    /// Preserve all AI models (even removed ones), repairing duplicate IDs and singleton services.
    func normalized() -> Self {
        var singleton = Set<String>()
        var result: [AskTranslationService] = []
        for service in services {
            let key = service.provider.map { "provider." + $0.rawValue } ?? (service.kind == .device ? "device" : nil)
            if let key, !singleton.insert(key).inserted { continue }
            result.append(service)
        }
        if !result.contains(where: \.isAI) { result.append(.ai(enabled: false)) }
        if !singleton.contains("device") { var device = AskTranslationService.device; device.enabled = false; result.append(device) }
        for provider in AskTranslationProvider.allCases where !singleton.contains("provider." + provider.rawValue) {
            result.append(.provider(provider))
        }
        var ids = Set<String>()
        for index in result.indices {
            if result[index].id.isEmpty || !ids.insert(result[index].id).inserted {
                result[index].id = UUID().uuidString
                ids.insert(result[index].id)
            }
        }
        var normalized = self
        normalized.services = result
        return normalized
    }

    /// v1 remains on disk for rollback. The removed fallback flag has no effect.
    static func migrateV1(_ data: Data) -> Self? {
        struct Legacy: Decodable {
            var engine: String?
            var modelReference: String?
            var prefersOnDevice: Bool?
        }
        guard let old = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        var services: [AskTranslationService] = []
        if old.prefersOnDevice ?? true { services.append(.device) }
        let provider = old.engine.flatMap(AskTranslationProvider.init(rawValue:))
        if let provider { services.append(.provider(provider, enabled: true)) }
        services.append(.ai(modelReference: old.modelReference ?? ""))
        if old.prefersOnDevice == false { var device = AskTranslationService.device; device.enabled = false; services.append(device) }
        services += AskTranslationProvider.allCases.filter { $0 != provider }.map { .provider($0) }
        return Self(services: services)
    }
}

extension SettingsStore {
    static let askTranslationSettingsKey = "ask.translation.settings.v2"
    static let askTranslationLegacySettingsKey = "ask.translation.settings.v1"

    var askTranslationSettings: AskTranslationSettings {
        get {
            if let data = defaults.data(forKey: Self.askTranslationSettingsKey),
               let settings = try? JSONDecoder().decode(AskTranslationSettings.self, from: data) {
                let normalized = settings.normalized()
                if normalized != settings, let data = try? JSONEncoder().encode(normalized) {
                    defaults.set(data, forKey: Self.askTranslationSettingsKey)
                }
                return normalized
            }
            let migrated = defaults.data(forKey: Self.askTranslationLegacySettingsKey)
                .flatMap(AskTranslationSettings.migrateV1) ?? AskTranslationSettings()
            if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: Self.askTranslationSettingsKey) }
            return migrated
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.normalized()) { defaults.set(data, forKey: Self.askTranslationSettingsKey) }
        }
    }

    /// The model AI translations and word cards use: the one chosen for translation,
    /// or the text-processing model. A chosen model that was removed stays unavailable
    /// rather than quietly switching to another one.
    func translationLLMConfiguration(reference: String? = nil) -> TextLLMConfiguration {
        let reference = reference ?? askTranslationSettings.modelReference
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
