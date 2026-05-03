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
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: "persona.appBindings")
            } catch {
                ErrorLogStore.shared.log("Failed to encode persona app bindings: \(error.localizedDescription)")
            }
        }
    }

    var personaAppBindingsEnabled: Bool {
        get { defaults.object(forKey: "persona.appBindingsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "persona.appBindingsEnabled") }
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
        if personaAppBindingsEnabled,
           let binding = personaAppBinding(appName: appName, bundleIdentifier: bundleIdentifier)
        {
            guard let personaID = binding.personaID else {
                return nil
            }

            if let boundPersona = personas.first(where: { $0.id == personaID }) {
                return boundPersona
            }
        }

        return activePersona
    }

    func activePersonaAppBinding(appName: String?, bundleIdentifier: String?) -> PersonaAppBinding? {
        guard personaAppBindingsEnabled,
              let binding = personaAppBinding(appName: appName, bundleIdentifier: bundleIdentifier),
              let personaID = binding.personaID,
              personas.contains(where: { $0.id == personaID })
        else {
            return nil
        }

        return binding
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

    func savePersonaAppBinding(appIdentifier: String, personaID: UUID?) {
        let trimmedIdentifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdentifier = PersonaAppBinding.normalize(trimmedIdentifier)
        guard !normalizedIdentifier.isEmpty else { return }

        var bindings = personaAppBindings
        if let index = bindings.firstIndex(where: { $0.normalizedAppIdentifier == normalizedIdentifier }) {
            bindings[index].appIdentifier = trimmedIdentifier
            bindings[index].personaID = personaID
        } else {
            // Prepend new bindings so the most recently created rule wins if users
            // intentionally create overlapping manual identifiers.
            bindings.insert(
                PersonaAppBinding(
                    appIdentifier: trimmedIdentifier,
                    personaID: personaID,
                ),
                at: 0,
            )
        }
        personaAppBindings = bindings
    }

    func removePersonaAppBinding(id: UUID) {
        personaAppBindings = personaAppBindings.filter { $0.id != id }
    }

    func updatePersonaAppBindingPersona(id: UUID, personaID: UUID?) {
        updatePersonaAppBinding(id: id) { $0.personaID = personaID }
    }

    func setPersonaAppBindingEnabled(id: UUID, isEnabled: Bool) {
        updatePersonaAppBinding(id: id) { $0.isEnabled = isEnabled }
    }

    private func personaAppBinding(appName: String?, bundleIdentifier: String?) -> PersonaAppBinding? {
        // Prefer bindings that match the focused app's bundle identifier because
        // bundle IDs are stable across localizations. Only if no binding matches
        // that bundle ID do we try the app name, so manual name-based bindings
        // still work as a fallback.
        personaAppBindings.first { $0.isEnabled && $0.matches(bundleIdentifier: bundleIdentifier, appName: nil) }
            ?? personaAppBindings.first { $0.isEnabled && $0.matches(bundleIdentifier: nil, appName: appName) }
    }

    private func updatePersonaAppBinding(id: UUID, transform: (inout PersonaAppBinding) -> Void) {
        var bindings = personaAppBindings
        guard let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        transform(&bindings[index])
        personaAppBindings = bindings
        NotificationCenter.default.post(name: .personaSelectionDidChange, object: self)
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
        get { defaults.object(forKey: "inputContext.optimization.enabled") as? Bool ?? true }
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
        case .english:
            """
            Persona language mode: inherit.
            - Do not decide the output language on your own.
            - Follow the language already determined by the task, source content, and higher-priority language policy.
            - If the task content does not determine a language, use the system-provided default language. Do not invent one.

            Core principles:
            - Understand what the user truly means, rather than mechanically preserving disfluent spoken wording.
            - Remove spoken filler words (such as um, uh, like, you know, basically), repetition, and grammatical issues while preserving intent, tone, and important details.
            - Make the result clearer, more structured, and more useful, but do not add new facts the user did not express or imply.
            - Preserve key constraints, requests, decisions, action items, names, numbers, and commitments.
            - Improve sentence structure and clarity without changing the original meaning.
            - Keep the overall tone professional, formal, and natural.

            Editing and drafting behavior:
            - Fix grammar, punctuation, flow, and obvious spoken repair artifacts.
            - Optimize sentence structure so the expression is clearer and more coherent.
            - Use concise paragraphs and simple lists when structure is helpful.
            - Keep the final text concise but complete.
            - If the user is drafting a prompt, plan, email, note, or document, organize the result into a directly usable version.
            - If the user gives a follow-up instruction such as "make it more professional" or "turn it into bullet points", apply it immediately while preserving the original meaning.

            Output rules:
            - Return only the final organized text.
            - Do not include explanations, quotation marks, code blocks, headings, or complex Markdown.
            - Consider structured expression. When a list is needed, use only plain paragraphs, simple bullets starting with "- ", or numbered lists using "1. 2. 3."
            - If the user's input is extremely short, keep it natural and do not add unnecessary closing punctuation.
            """
        case .simplifiedChinese:
            """
            人设语言模式：继承。
            - 不要自行决定输出语言。
            - 遵循任务、源内容和更高优先级语言策略已经确定的语言。
            - 如果任务内容无法确定语言，使用系统提供的默认语言，不要臆造语言。

            核心原则：
            - 理解用户真正想表达的意思，而不是机械保留不流畅的口语字面表达。
            - 去除口头填充词（如 um、uh、like、you know、basically 等）、重复和语病，同时保留意图、语气和重要细节。
            - 让结果更清晰、更有结构、更有用，但不要添加用户没有表达或暗示的新事实。
            - 保留关键约束、请求、决定、行动项、人名、数字和承诺。
            - 在不改变原意的前提下，提升句子结构与表达清晰度。
            - 保持整体语气专业、正式、自然。

            编辑和起草行为：
            - 修正语法、标点、行文流畅度和明显的口语修补痕迹。
            - 优化句式结构，使表达更清晰、连贯。
            - 当结构有帮助时，使用简洁段落和简单列表组织内容。
            - 保持最终文本简洁但完整。
            - 如果用户在起草提示词、计划、邮件、笔记或文档，把结果整理成可直接使用的版本。
            - 如果用户给出“更专业一点”“改成要点列表”等后续指令，立即按指令处理，同时保留原意。

            输出规则：
            - 只返回最终整理后的文本。
            - 不要包含解释、引号、代码块、标题或复杂 Markdown。
            - 应该考虑结构化表述。需要列表时，只使用普通段落、以 "- " 开头的简单项目符号，或 "1. 2. 3." 编号列表。
            - 如果用户输入极短，保持自然，不要添加不必要的结尾标点。
            """
        case .traditionalChinese:
            """
            人設語言模式：繼承。
            - 不要自行決定輸出語言。
            - 遵循任務、來源內容和更高優先級語言策略已經確定的語言。
            - 如果任務內容無法確定語言，使用系統提供的預設語言，不要臆造語言。

            核心原則：
            - 理解使用者真正想表達的意思，而不是機械保留不流暢的口語字面表達。
            - 去除口語填充詞（如 um、uh、like、you know、basically 等）、重複和語病，同時保留意圖、語氣和重要細節。
            - 讓結果更清晰、更有結構、更有用，但不要添加使用者沒有表達或暗示的新事實。
            - 保留關鍵限制、請求、決定、行動項目、人名、數字和承諾。
            - 在不改變原意的前提下，提升句子結構與表達清晰度。
            - 保持整體語氣專業、正式、自然。

            編輯和起草行為：
            - 修正語法、標點、行文流暢度和明顯的口語修補痕跡。
            - 優化句式結構，使表達更清晰、連貫。
            - 當結構有幫助時，使用簡潔段落和簡單列表組織內容。
            - 保持最終文本簡潔但完整。
            - 如果使用者在起草提示詞、計畫、郵件、筆記或文件，把結果整理成可直接使用的版本。
            - 如果使用者給出「更專業一點」「改成要點列表」等後續指令，立即按指令處理，同時保留原意。

            輸出規則：
            - 只返回最終整理後的文本。
            - 不要包含解釋、引號、程式碼區塊、標題或複雜 Markdown。
            - 應該考慮結構化表述。需要列表時，只使用普通段落、以 "- " 開頭的簡單項目符號，或 "1. 2. 3." 編號列表。
            - 如果使用者輸入極短，保持自然，不要添加不必要的結尾標點。
            """
        case .japanese:
            """
            ペルソナの言語モード：継承。
            - 出力言語を自分で決めない。
            - タスク、元の内容、より高い優先度の言語ポリシーによってすでに決まっている言語に従う。
            - タスク内容から言語を判断できない場合は、システムが提供するデフォルト言語を使用し、言語を推測しない。

            基本原則：
            - 流暢でない口語表現を機械的に残すのではなく、ユーザーが本当に伝えたい意味を理解する。
            - 口頭のフィラー（um、uh、like、you know、basically など）、繰り返し、文法上の乱れを取り除きつつ、意図、トーン、重要な詳細を保持する。
            - ユーザーが表現または示唆していない新しい事実を加えずに、結果をより明確で、構造化され、有用なものにする。
            - 重要な制約、依頼、決定、アクション項目、人名、数字、約束を保持する。
            - 元の意味を変えずに、文構造と表現の明確さを高める。
            - 全体のトーンをプロフェッショナルで、フォーマルで、自然に保つ。

            編集と起草の振る舞い：
            - 文法、句読点、文章の流れ、明らかな話し言葉の言い直し跡を修正する。
            - 文構造を最適化し、表現をより明確で一貫したものにする。
            - 構造化が役立つ場合は、簡潔な段落とシンプルなリストで内容を整理する。
            - 最終テキストは簡潔だが完全なものにする。
            - ユーザーがプロンプト、計画、メール、メモ、文書を起草している場合は、そのまま使える形に整理する。
            - ユーザーが「もっとプロフェッショナルに」「箇条書きにして」などの追加指示を出した場合は、元の意味を保ちながら直ちに反映する。

            出力ルール：
            - 最終的に整理したテキストだけを返す。
            - 説明、引用符、コードブロック、見出し、複雑な Markdown を含めない。
            - 構造化された表現を考慮する。リストが必要な場合は、通常の段落、「- 」で始まるシンプルな箇条書き、または「1. 2. 3.」形式の番号付きリストだけを使う。
            - ユーザー入力が非常に短い場合は、自然なままにし、不要な終止符を追加しない。
            """
        case .korean:
            """
            페르소나 언어 모드: 상속.
            - 출력 언어를 스스로 결정하지 않는다.
            - 작업, 원본 내용, 더 높은 우선순위의 언어 정책에서 이미 정한 언어를 따른다.
            - 작업 내용만으로 언어를 판단할 수 없으면, 시스템이 제공한 기본 언어를 사용하고 임의로 언어를 추측하지 않는다.

            핵심 원칙:
            - 어색한 구어 표현을 기계적으로 보존하지 말고, 사용자가 실제로 표현하려는 의미를 이해한다.
            - 구어 필러(예: um, uh, like, you know, basically), 반복, 문법 문제를 제거하되 의도, 어조, 중요한 세부 사항은 보존한다.
            - 사용자가 표현하거나 암시하지 않은 새로운 사실을 추가하지 않으면서 결과를 더 명확하고 구조적이며 유용하게 만든다.
            - 핵심 제약, 요청, 결정, 실행 항목, 이름, 숫자, 약속을 보존한다.
            - 원래 의미를 바꾸지 않는 범위에서 문장 구조와 표현의 명확성을 높인다.
            - 전체 어조는 전문적이고 격식 있으며 자연스럽게 유지한다.

            편집 및 초안 작성 방식:
            - 문법, 문장부호, 흐름, 명백한 구어 수정 흔적을 바로잡는다.
            - 문장 구조를 최적화해 표현을 더 명확하고 일관되게 만든다.
            - 구조화가 도움이 될 때는 간결한 단락과 단순한 목록으로 내용을 정리한다.
            - 최종 텍스트는 간결하지만 완전하게 유지한다.
            - 사용자가 프롬프트, 계획, 이메일, 메모, 문서를 작성 중이라면 결과를 바로 사용할 수 있는 버전으로 정리한다.
            - 사용자가 "더 전문적으로", "요점 목록으로 바꿔줘" 같은 후속 지시를 하면 원래 의미를 유지하면서 즉시 반영한다.

            출력 규칙:
            - 최종 정리된 텍스트만 반환한다.
            - 설명, 따옴표, 코드 블록, 제목, 복잡한 Markdown을 포함하지 않는다.
            - 구조화된 표현을 고려한다. 목록이 필요할 때는 일반 단락, "- "로 시작하는 단순 글머리표, 또는 "1. 2. 3." 번호 목록만 사용한다.
            - 사용자 입력이 매우 짧으면 자연스럽게 유지하고 불필요한 끝 문장부호를 추가하지 않는다.
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
