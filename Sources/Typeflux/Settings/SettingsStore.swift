import Foundation

// swiftlint:disable type_body_length file_length
extension Notification.Name {
    static let personaSelectionDidChange = Notification.Name(
        "SettingsStore.personaSelectionDidChange",
    )
    static let appearanceModeDidChange = Notification.Name("SettingsStore.appearanceModeDidChange")
    static let agentConfigurationDidChange = Notification.Name("SettingsStore.agentConfigurationDidChange")
    static let localOptimizationDidEnable = Notification.Name("SettingsStore.localOptimizationDidEnable")
}

enum HistoryRetentionPolicy: String, CaseIterable, Identifiable {
    case never
    case oneDay
    case oneWeek
    case oneMonth
    case forever

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .never:
            L("history.retention.never.title")
        case .oneDay:
            L("history.retention.oneDay.title")
        case .oneWeek:
            L("history.retention.oneWeek.title")
        case .oneMonth:
            L("history.retention.oneMonth.title")
        case .forever:
            L("history.retention.forever.title")
        }
    }

    var detail: String {
        switch self {
        case .never:
            L("history.retention.never.detail")
        case .oneDay:
            L("history.retention.oneDay.detail")
        case .oneWeek:
            L("history.retention.oneWeek.detail")
        case .oneMonth:
            L("history.retention.oneMonth.detail")
        case .forever:
            L("history.retention.forever.detail")
        }
    }

    var days: Int? {
        switch self {
        case .never:
            0
        case .oneDay:
            1
        case .oneWeek:
            7
        case .oneMonth:
            30
        case .forever:
            nil
        }
    }
}

final class SettingsStore {
    struct TextLLMConfiguration {
        let provider: LLMRemoteProvider
        let baseURL: String
        let model: String
        let apiKey: String
    }

    /// Identifier of the built-in "Typeflux" persona. Used as the smart default
    /// persona for new users whose LLM is already configured.
    static let defaultPersonaID = UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA001")!

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appLanguage: AppLanguage {
        get {
            guard
                let raw = defaults.string(forKey: "ui.language"),
                let language = AppLanguage(rawValue: raw)
            else {
                return AppLanguage.defaultLanguage()
            }

            return language
        }
        set { defaults.set(newValue.rawValue, forKey: "ui.language") }
    }

    var sttProvider: STTProvider {
        get {
            let raw = defaults.string(forKey: "stt.provider") ?? STTProvider.defaultProvider.rawValue
            return STTProvider(rawValue: raw) ?? STTProvider.defaultProvider
        }
        set { defaults.set(newValue.rawValue, forKey: "stt.provider") }
    }

    var llmProvider: LLMProvider {
        get {
            let raw =
                defaults.string(forKey: "llm.provider") ?? LLMProvider.openAICompatible.rawValue
            return LLMProvider(rawValue: raw) ?? .openAICompatible
        }
        set { defaults.set(newValue.rawValue, forKey: "llm.provider") }
    }

    var llmRemoteProvider: LLMRemoteProvider {
        get {
            let raw =
                defaults.string(forKey: "llm.remote.provider") ?? LLMRemoteProvider.defaultProvider.rawValue
            return LLMRemoteProvider(rawValue: raw) ?? LLMRemoteProvider.defaultProvider
        }
        set { defaults.set(newValue.rawValue, forKey: "llm.remote.provider") }
    }

    var appearanceMode: AppearanceMode {
        get {
            let raw = defaults.string(forKey: "ui.appearance") ?? AppearanceMode.system.rawValue
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set {
            let currentValue = appearanceMode
            guard currentValue != newValue else { return }
            defaults.set(newValue.rawValue, forKey: "ui.appearance")
            NotificationCenter.default.post(name: .appearanceModeDidChange, object: self)
        }
    }

    var preferredMicrophoneID: String {
        get {
            defaults.string(forKey: "audio.input.preferredMicrophoneID")
                ?? AudioDeviceManager.automaticDeviceID
        }
        set { defaults.set(newValue, forKey: "audio.input.preferredMicrophoneID") }
    }

    var muteSystemOutputDuringRecording: Bool {
        get { defaults.object(forKey: "audio.recording.muteSystemOutput") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "audio.recording.muteSystemOutput") }
    }

    var soundEffectsEnabled: Bool {
        get { defaults.object(forKey: "audio.soundEffects.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "audio.soundEffects.enabled") }
    }

    var autoUpdateEnabled: Bool {
        get { defaults.object(forKey: "app.autoUpdate.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "app.autoUpdate.enabled") }
    }

    var historyRetentionPolicy: HistoryRetentionPolicy {
        get {
            let raw =
                defaults.string(forKey: "history.retentionPolicy")
                    ?? HistoryRetentionPolicy.oneWeek.rawValue
            return HistoryRetentionPolicy(rawValue: raw) ?? .oneWeek
        }
        set { defaults.set(newValue.rawValue, forKey: "history.retentionPolicy") }
    }

    var llmBaseURL: String {
        get { llmBaseURL(for: llmRemoteProvider) }
        set { setLLMBaseURL(newValue, for: llmRemoteProvider) }
    }

    var llmModel: String {
        get { llmModel(for: llmRemoteProvider) }
        set { setLLMModel(newValue, for: llmRemoteProvider) }
    }

    var llmAPIKey: String {
        get { llmAPIKey(for: llmRemoteProvider) }
        set { setLLMAPIKey(newValue, for: llmRemoteProvider) }
    }

    var ollamaBaseURL: String {
        get { defaults.string(forKey: "llm.ollama.baseURL") ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: "llm.ollama.baseURL") }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: "llm.ollama.model") ?? "qwen3.5:7b" }
        set { defaults.set(newValue, forKey: "llm.ollama.model") }
    }

    var ollamaAutoSetup: Bool {
        get { defaults.object(forKey: "llm.ollama.autoSetup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "llm.ollama.autoSetup") }
    }

    var whisperBaseURL: String {
        get { defaults.string(forKey: "stt.whisper.baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "stt.whisper.baseURL") }
    }

    var whisperModel: String {
        get { defaults.string(forKey: "stt.whisper.model") ?? "" }
        set { defaults.set(newValue, forKey: "stt.whisper.model") }
    }

    var whisperAPIKey: String {
        get { defaults.string(forKey: "stt.whisper.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "stt.whisper.apiKey") }
    }

    var freeSTTModel: String {
        get { defaults.string(forKey: "stt.free.model") ?? (FreeSTTModelRegistry.suggestedModelNames.first ?? "") }
        set { defaults.set(newValue, forKey: "stt.free.model") }
    }

    var localSTTModel: LocalSTTModel {
        get {
            let raw =
                defaults.string(forKey: "stt.local.model") ?? LocalSTTModel.defaultModel.rawValue
            return LocalSTTModel(rawValue: raw) ?? LocalSTTModel.defaultModel
        }
        set { defaults.set(newValue.rawValue, forKey: "stt.local.model") }
    }

    var localSTTModelIdentifier: String {
        get {
            let fallback = localSTTModel.defaultModelIdentifier
            return defaults.string(forKey: "stt.local.modelIdentifier") ?? fallback
        }
        set { defaults.set(newValue, forKey: "stt.local.modelIdentifier") }
    }

    var localSTTDownloadSource: ModelDownloadSource {
        get {
            let raw =
                defaults.string(forKey: "stt.local.downloadSource")
                    ?? localSTTModel.recommendedDownloadSource.rawValue
            return ModelDownloadSource(rawValue: raw) ?? localSTTModel.recommendedDownloadSource
        }
        set { defaults.set(newValue.rawValue, forKey: "stt.local.downloadSource") }
    }

    var localSTTAutoSetup: Bool {
        get { defaults.object(forKey: "stt.local.autoSetup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stt.local.autoSetup") }
    }

    var multimodalLLMBaseURL: String {
        get { defaults.string(forKey: "stt.multimodal.baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "stt.multimodal.baseURL") }
    }

    var aliCloudAPIKey: String {
        get { defaults.string(forKey: "stt.alicloud.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "stt.alicloud.apiKey") }
    }

    var aliCloudModel: String {
        get { AliCloudASRDefaults.model }
        set { defaults.removeObject(forKey: "stt.alicloud.model") }
    }

    var doubaoAppID: String {
        get { defaults.string(forKey: "stt.doubao.appID") ?? "" }
        set { defaults.set(newValue, forKey: "stt.doubao.appID") }
    }

    var doubaoAccessToken: String {
        get { defaults.string(forKey: "stt.doubao.accessToken") ?? "" }
        set { defaults.set(newValue, forKey: "stt.doubao.accessToken") }
    }

    var doubaoResourceID: String {
        get {
            let stored =
                defaults.string(forKey: "stt.doubao.resourceID")?.trimmingCharacters(
                    in: .whitespacesAndNewlines,
                ) ?? ""
            if stored.isEmpty || stored == "volc.bigasr.sauc.duration" {
                return "volc.seedasr.sauc.duration"
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "stt.doubao.resourceID") }
    }

    var googleCloudProjectID: String {
        get { defaults.string(forKey: "stt.google.projectID") ?? "" }
        set { defaults.set(newValue, forKey: "stt.google.projectID") }
    }

    var googleCloudAPIKey: String {
        get { defaults.string(forKey: "stt.google.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "stt.google.apiKey") }
    }

    var googleCloudModel: String {
        get { defaults.string(forKey: "stt.google.model") ?? GoogleCloudSpeechDefaults.model }
        set { defaults.set(newValue, forKey: "stt.google.model") }
    }

    var groqSTTAPIKey: String {
        get { defaults.string(forKey: "stt.groq.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "stt.groq.apiKey") }
    }

    var groqSTTModel: String {
        get { defaults.string(forKey: "stt.groq.model") ?? "" }
        set { defaults.set(newValue, forKey: "stt.groq.model") }
    }

    var multimodalLLMModel: String {
        get { defaults.string(forKey: "stt.multimodal.model") ?? "" }
        set { defaults.set(newValue, forKey: "stt.multimodal.model") }
    }

    var multimodalLLMAPIKey: String {
        get { defaults.string(forKey: "stt.multimodal.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "stt.multimodal.apiKey") }
    }

    var personaRewriteEnabled: Bool {
        get { defaults.object(forKey: "persona.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "persona.enabled") }
    }

    var personaHotkeyAppliesToSelection: Bool {
        get { defaults.object(forKey: "persona.hotkeyAppliesToSelection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "persona.hotkeyAppliesToSelection") }
    }

    var activePersonaID: String {
        get { defaults.string(forKey: "persona.activeID") ?? "" }
        set { defaults.set(newValue, forKey: "persona.activeID") }
    }

    /// Tracks whether the user has explicitly chosen a persona state (including
    /// explicitly choosing "none"). Used to distinguish a first-run user who has
    /// never touched the persona setting from a user who deliberately turned it off.
    /// Only the first group is eligible for the Typeflux smart default.
    var personaSelectionIsExplicit: Bool {
        get { defaults.object(forKey: "persona.selectionIsExplicit") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "persona.selectionIsExplicit") }
    }

    var personasJSON: String {
        get { defaults.string(forKey: "persona.items") ?? "" }
        set { defaults.set(newValue, forKey: "persona.items") }
    }

    var personaAppBindings: [PersonaAppBinding] {
        get {
            guard let data = defaults.data(forKey: "persona.appBindings") else {
                return []
            }
            return (try? JSONDecoder().decode([PersonaAppBinding].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            defaults.set(data, forKey: "persona.appBindings")
        }
    }

    var personas: [PersonaProfile] {
        get {
            guard let data = personasJSON.data(using: .utf8), !personasJSON.isEmpty else {
                return systemPersonas
            }
            let decoded = (try? JSONDecoder().decode([PersonaProfile].self, from: data)) ?? []
            return mergedPersonas(from: decoded)
        }
        set {
            let customPersonas = newValue.filter { !$0.isSystem }
            let data = (try? JSONEncoder().encode(customPersonas)) ?? Data("[]".utf8)
            personasJSON = String(decoding: data, as: UTF8.self)
        }
    }

    var activePersona: PersonaProfile? {
        guard personaRewriteEnabled else { return nil }
        return personas.first { $0.id.uuidString == activePersonaID }
    }

    var activePersonaPrompt: String? {
        guard let activePersona else { return nil }
        return resolvedPersonaPrompt(for: activePersona)
    }

    func effectivePersona(appName: String?, bundleIdentifier: String?) -> PersonaProfile? {
        if let binding = personaAppBinding(appName: appName, bundleIdentifier: bundleIdentifier),
           let boundPersona = personas.first(where: { $0.id == binding.personaID })
        {
            return boundPersona
        }

        return activePersona
    }

    func effectivePersonaPrompt(appName: String?, bundleIdentifier: String?) -> String? {
        guard let persona = effectivePersona(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return resolvedPersonaPrompt(for: persona)
    }

    func resolvedPersonaPrompt(for persona: PersonaProfile) -> String {
        guard persona.isSystem else { return persona.prompt }

        if persona.id == Self.defaultPersonaID {
            return Self.typefluxPersonaPrompt(appLanguage: appLanguage)
        }

        if persona.id == UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002")! {
            return Self.englishTranslatorPersonaPrompt()
        }

        return persona.prompt
    }

    func applyPersonaSelection(_ personaID: UUID?) {
        if let personaID {
            activePersonaID = personaID.uuidString
            personaRewriteEnabled = true
        } else {
            activePersonaID = ""
            personaRewriteEnabled = false
        }
        personaSelectionIsExplicit = true

        NotificationCenter.default.post(name: .personaSelectionDidChange, object: self)
    }

    func savePersonaAppBinding(appIdentifier: String, personaID: UUID) {
        let normalizedIdentifier = PersonaAppBinding.normalize(appIdentifier)
        guard !normalizedIdentifier.isEmpty else { return }

        var bindings = personaAppBindings
        if let index = bindings.firstIndex(where: { $0.normalizedAppIdentifier == normalizedIdentifier }) {
            bindings[index].appIdentifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            bindings[index].personaID = personaID
        } else {
            bindings.insert(
                PersonaAppBinding(
                    appIdentifier: appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                    personaID: personaID,
                ),
                at: 0,
            )
        }
        personaAppBindings = bindings
    }

    func removePersonaAppBinding(id: UUID) {
        personaAppBindings.removeAll { $0.id == id }
    }

    private func personaAppBinding(appName: String?, bundleIdentifier: String?) -> PersonaAppBinding? {
        let bindings = personaAppBindings

        if let bundleIdentifier {
            let normalizedBundleIdentifier = PersonaAppBinding.normalize(bundleIdentifier)
            if let match = bindings.first(where: { $0.normalizedAppIdentifier == normalizedBundleIdentifier }) {
                return match
            }
        }

        if let appName {
            let normalizedAppName = PersonaAppBinding.normalize(appName)
            if let match = bindings.first(where: { $0.normalizedAppIdentifier == normalizedAppName }) {
                return match
            }
        }

        return nil
    }

    /// If the LLM is currently configured and the user has not yet explicitly
    /// chosen a persona state, select the built-in Typeflux persona so users
    /// benefit from rewriting as soon as they have an LLM to talk to. Never
    /// overrides an explicit choice — including an explicit "none".
    /// Returns true if the default was applied.
    @discardableResult
    func applyDefaultPersonaIfLLMConfigured() -> Bool {
        guard !personaSelectionIsExplicit else { return false }
        guard isLLMConfigured else { return false }
        applyPersonaSelection(SettingsStore.defaultPersonaID)
        return true
    }

    func llmBaseURL(for provider: LLMRemoteProvider) -> String {
        if provider == .freeModel {
            return FreeLLMModelRegistry.resolve(modelName: llmModel(for: provider))?.baseURL ?? ""
        }
        let key = llmRemoteKey(provider, suffix: "baseURL")
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        if provider == .custom {
            return defaults.string(forKey: "llm.baseURL") ?? ""
        }
        return provider.defaultBaseURL
    }

    func setLLMBaseURL(_ value: String, for provider: LLMRemoteProvider) {
        defaults.set(value, forKey: llmRemoteKey(provider, suffix: "baseURL"))
        if provider == llmRemoteProvider {
            defaults.set(value, forKey: "llm.baseURL")
        }
    }

    func llmModel(for provider: LLMRemoteProvider) -> String {
        let key = llmRemoteKey(provider, suffix: "model")
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        if provider == .freeModel {
            return FreeLLMModelRegistry.suggestedModelNames.first ?? ""
        }
        if provider == .custom {
            return defaults.string(forKey: "llm.model") ?? ""
        }
        return provider.defaultModel
    }

    func setLLMModel(_ value: String, for provider: LLMRemoteProvider) {
        defaults.set(value, forKey: llmRemoteKey(provider, suffix: "model"))
        if provider == llmRemoteProvider {
            defaults.set(value, forKey: "llm.model")
        }
    }

    func llmAPIKey(for provider: LLMRemoteProvider) -> String {
        if provider == .freeModel {
            return FreeLLMModelRegistry.resolve(modelName: llmModel(for: provider))?.apiKey ?? ""
        }
        let key = llmRemoteKey(provider, suffix: "apiKey")
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        if provider == .custom {
            return defaults.string(forKey: "llm.apiKey") ?? ""
        }
        return ""
    }

    func setLLMAPIKey(_ value: String, for provider: LLMRemoteProvider) {
        defaults.set(value, forKey: llmRemoteKey(provider, suffix: "apiKey"))
        if provider == llmRemoteProvider {
            defaults.set(value, forKey: "llm.apiKey")
        }
    }

    /// Whether the current LLM selection has everything it needs to dispatch a request.
    /// Used to drive first-run smart defaults such as auto-selecting the built-in persona.
    /// `typefluxCloud` is treated as configured whenever selected (auth is carried by JWT,
    /// not by base URL / API key here); transient auth failures surface at request time.
    var isLLMConfigured: Bool {
        switch llmProvider {
        case .ollama:
            let baseURL = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return !baseURL.isEmpty && !model.isEmpty
        case .openAICompatible:
            switch llmRemoteProvider {
            case .typefluxCloud:
                return true
            case .freeModel:
                return !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .custom:
                let baseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
                return !baseURL.isEmpty && !model.isEmpty
            default:
                let baseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let apiKey = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty
            }
        }
    }

    func textLLMConfiguration() -> TextLLMConfiguration {
        if shouldUseMultimodalTextLLMFallback {
            let fallbackModel = multimodalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return TextLLMConfiguration(
                provider: .custom,
                baseURL: multimodalLLMBaseURL,
                model: fallbackModel.isEmpty ? OpenAIAudioModelCatalog.multimodalModels[0] : fallbackModel,
                apiKey: multimodalLLMAPIKey,
            )
        }

        return TextLLMConfiguration(
            provider: llmRemoteProvider,
            baseURL: llmBaseURL,
            model: llmModel,
            apiKey: llmAPIKey,
        )
    }

    var useAppleSpeechFallback: Bool {
        get { defaults.object(forKey: "stt.appleSpeech.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "stt.appleSpeech.enabled") }
    }

    var localOptimizationEnabled: Bool {
        get { defaults.object(forKey: "stt.localOptimization.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stt.localOptimization.enabled") }
    }

    var lastTypefluxCloudLoginReminderAt: Date? {
        get {
            guard defaults.object(forKey: "typefluxCloud.loginReminder.lastShownAt") != nil else {
                return nil
            }
            return Date(timeIntervalSince1970: defaults.double(forKey: "typefluxCloud.loginReminder.lastShownAt"))
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: "typefluxCloud.loginReminder.lastShownAt")
            } else {
                defaults.removeObject(forKey: "typefluxCloud.loginReminder.lastShownAt")
            }
        }
    }

    var localSTTMemoryOptimizationEnabled: Bool {
        get { defaults.object(forKey: "stt.local.memoryOptimization.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "stt.local.memoryOptimization.enabled") }
    }

    var automaticVocabularyCollectionEnabled: Bool {
        get { defaults.object(forKey: "vocabulary.automaticCollection.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vocabulary.automaticCollection.enabled") }
    }

    var inputContextOptimizationEnabled: Bool {
        get { defaults.object(forKey: "inputContext.optimization.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "inputContext.optimization.enabled") }
    }

    var activationHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.activation.json") ?? "" }
        set { defaults.set(newValue, forKey: "hotkey.activation.json") }
    }

    var activationHotkey: HotkeyBinding? {
        get {
            if activationHotkeyJSON == "__unset__" { return nil }
            if let migrated = legacyActivationHotkey {
                return migrated
            }

            guard let data = activationHotkeyJSON.data(using: .utf8), !activationHotkeyJSON.isEmpty
            else {
                return .defaultActivation
            }

            return (try? JSONDecoder().decode(HotkeyBinding.self, from: data)) ?? .defaultActivation
        }
        set {
            if let newValue {
                let data = (try? JSONEncoder().encode(newValue)) ?? Data()
                activationHotkeyJSON = String(decoding: data, as: UTF8.self)
            } else {
                activationHotkeyJSON = "__unset__"
            }
            defaults.removeObject(forKey: "hotkey.custom.json")
        }
    }

    var askHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.ask.json") ?? "" }
        set { defaults.set(newValue, forKey: "hotkey.ask.json") }
    }

    var askHotkey: HotkeyBinding? {
        get {
            if askHotkeyJSON == "__unset__" { return nil }
            guard let data = askHotkeyJSON.data(using: .utf8), !askHotkeyJSON.isEmpty else {
                return .defaultAsk
            }

            return (try? JSONDecoder().decode(HotkeyBinding.self, from: data)) ?? .defaultAsk
        }
        set {
            if let newValue {
                let data = (try? JSONEncoder().encode(newValue)) ?? Data()
                askHotkeyJSON = String(decoding: data, as: UTF8.self)
            } else {
                askHotkeyJSON = "__unset__"
            }
        }
    }

    var personaHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.persona.json") ?? "" }
        set { defaults.set(newValue, forKey: "hotkey.persona.json") }
    }

    var personaHotkey: HotkeyBinding? {
        get {
            if personaHotkeyJSON == "__unset__" { return nil }
            guard let data = personaHotkeyJSON.data(using: .utf8), !personaHotkeyJSON.isEmpty else {
                return .defaultPersona
            }

            return (try? JSONDecoder().decode(HotkeyBinding.self, from: data)) ?? .defaultPersona
        }
        set {
            if let newValue {
                let data = (try? JSONEncoder().encode(newValue)) ?? Data()
                personaHotkeyJSON = String(decoding: data, as: UTF8.self)
            } else {
                personaHotkeyJSON = "__unset__"
            }
        }
    }

    private var legacyActivationHotkey: HotkeyBinding? {
        guard activationHotkeyJSON.isEmpty else { return nil }
        let legacyJSON = defaults.string(forKey: "hotkey.custom.json") ?? "[]"
        guard let data = legacyJSON.data(using: .utf8) else { return nil }
        let decoded = (try? JSONDecoder().decode([HotkeyBinding].self, from: data)) ?? []
        guard let first = decoded.first else { return nil }

        let migrated = HotkeyBinding(keyCode: first.keyCode, modifierFlags: first.modifierFlags)
        activationHotkey = migrated
        return migrated
    }

    private var systemPersonas: [PersonaProfile] {
        [
            PersonaProfile(
                id: Self.defaultPersonaID,
                name: "Typeflux",
                prompt: Self.typefluxPersonaPrompt(appLanguage: .english),
                kind: .system,
            ),
            PersonaProfile(
                id: UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002")!,
                name: "English Translator",
                prompt: Self.englishTranslatorPersonaPrompt(),
                kind: .system,
            ),
        ]
    }

    private static func typefluxPersonaPrompt(appLanguage: AppLanguage) -> String {
        switch appLanguage {
        case .simplifiedChinese:
            """
            人设语言模式：继承。
            - 不要自行决定输出语言。
            - 遵循任务、源内容和更高优先级语言策略已经确定的语言。
            - 如果任务内容无法确定语言，使用系统提供的默认语言，不要臆造语言。

            你是 Typeflux AI，一个以语音输入为核心的写作助手，负责把原始口述内容整理成可直接使用的文字。

            核心原则：
            - 理解用户真正想表达的意思，而不是机械保留不流畅的口语字面表达。
            - 去除口头填充词、重复和语病，同时保留意图、语气和重要细节。
            - 让结果更清晰、更有结构、更有用，但不要添加用户没有表达或暗示的新事实。
            - 保留关键约束、请求、决定、行动项、人名、数字和承诺。

            编辑和起草行为：
            - 修正语法、标点、行文流畅度和明显的口语修补痕迹。
            - 当结构有帮助时，使用简洁段落和简单列表组织内容。
            - 保持最终文本简洁但完整。
            - 如果用户在起草提示词、计划、邮件、笔记或文档，把结果整理成可直接使用的版本。
            - 如果用户给出“更专业一点”“改成要点列表”等后续指令，立即按指令处理，同时保留原意。

            输出规则：
            - 只返回最终整理后的文本。
            - 不要包含解释、引号、代码块、标题或复杂 Markdown。
            - 需要列表时，只使用普通段落、以 "- " 开头的简单项目符号，或 "1. 2. 3." 编号列表。
            - 如果用户输入极短，保持自然，不要添加不必要的结尾标点。
            """
        case .traditionalChinese:
            """
            人設語言模式：繼承。
            - 不要自行決定輸出語言。
            - 遵循任務、來源內容和更高優先級語言策略已經確定的語言。
            - 如果任務內容無法確定語言，使用系統提供的預設語言，不要臆造語言。

            你是 Typeflux AI，一個以語音輸入為核心的寫作助手，負責把原始口述內容整理成可直接使用的文字。

            核心原則：
            - 理解使用者真正想表達的意思，而不是機械保留不流暢的口語字面表達。
            - 去除口頭填充詞、重複和語病，同時保留意圖、語氣和重要細節。
            - 讓結果更清晰、更有結構、更有用，但不要添加使用者沒有表達或暗示的新事實。
            - 保留關鍵限制、請求、決定、行動項、人名、數字和承諾。

            編輯和起草行為：
            - 修正語法、標點、行文流暢度和明顯的口語修補痕跡。
            - 當結構有幫助時，使用簡潔段落和簡單列表組織內容。
            - 保持最終文本簡潔但完整。
            - 如果使用者在起草提示詞、計畫、郵件、筆記或文件，把結果整理成可直接使用的版本。
            - 如果使用者給出「更專業一點」「改成要點列表」等後續指令，立即按指令處理，同時保留原意。

            輸出規則：
            - 只返回最終整理後的文本。
            - 不要包含解釋、引號、程式碼區塊、標題或複雜 Markdown。
            - 需要列表時，只使用普通段落、以 "- " 開頭的簡單項目符號，或 "1. 2. 3." 編號列表。
            - 如果使用者輸入極短，保持自然，不要添加不必要的結尾標點。
            """
        case .english, .japanese, .korean:
            """
            Persona language mode: inherit.
            - Do not decide the output language on your own.
            - Follow the language already resolved by the task, source content, and higher-priority language policy.
            - If no task content determines the language, follow the system-provided default language instead of inventing one.

            You are Typeflux AI, a voice-first writing assistant that turns raw spoken input into polished, ready-to-use text.

            Core principles:
            - Extract what the user means, not just the literal disfluent wording.
            - Remove filler words, repetitions, and verbal tics while preserving intent, tone, and important detail.
            - Make the result clearer, more structured, and more useful without adding facts the user did not imply.
            - Preserve key constraints, requests, decisions, action items, names, numbers, and commitments.

            Editing and drafting behavior:
            - Clean grammar, punctuation, flow, and obvious speech-repair artifacts.
            - Organize content with plain paragraphs and simple lists when structure helps.
            - Keep the final text concise but complete.
            - If the user is drafting prompts, plans, emails, notes, or documentation, make the result directly usable.
            - If the user gives a follow-up instruction such as "make this more professional" or "turn this into bullet points", apply it immediately while preserving meaning.

            Output rules:
            - Return only the final polished text.
            - Do not include explanations, quotation marks, code fences, headings, or rich Markdown.
            - Use only plain paragraphs, simple bullet lists using "- ", or numbered lists using "1. 2. 3." when needed.
            - If the user's input is extremely short, keep the output natural and avoid unnecessary closing punctuation.
            """
        }
    }

    private static func englishTranslatorPersonaPrompt() -> String {
        """
        Persona language mode: fixed English.
        - Unless the user explicitly asks for a different language, always produce the final output in natural English.
        - When the source text is not in English, translate it into fluent English.
        - When the source text is already in English, improve clarity without changing the language.
        - Keep proper nouns in their natural form.
        """
    }

    private func mergedPersonas(from storedPersonas: [PersonaProfile]) -> [PersonaProfile] {
        let systemSignatureSet = Set(
            systemPersonas.map { systemPersona in
                personaSignature(name: systemPersona.name, prompt: systemPersona.prompt)
            },
        )

        let customPersonas = storedPersonas.compactMap { persona -> PersonaProfile? in
            let signature = personaSignature(name: persona.name, prompt: persona.prompt)
            guard !systemSignatureSet.contains(signature) else { return nil }
            return PersonaProfile(
                id: persona.id, name: persona.name, prompt: persona.prompt, kind: .custom,
            )
        }

        return systemPersonas + customPersonas
    }

    private func personaSignature(name: String, prompt: String) -> String {
        "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())::\(prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var isOnboardingCompleted: Bool {
        get { defaults.object(forKey: "onboarding.completed") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "onboarding.completed") }
    }

    private func llmRemoteKey(_ provider: LLMRemoteProvider, suffix: String) -> String {
        "llm.remote.\(provider.rawValue).\(suffix)"
    }

    private var shouldUseMultimodalTextLLMFallback: Bool {
        guard sttProvider == .multimodalLLM else { return false }
        guard llmProvider == .openAICompatible else { return false }
        guard !multimodalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        if llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        let providerRequiresAPIKey = llmRemoteProvider != .custom && llmRemoteProvider != .freeModel
            && llmRemoteProvider != .typefluxCloud
        return providerRequiresAPIKey
            && llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !multimodalLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
