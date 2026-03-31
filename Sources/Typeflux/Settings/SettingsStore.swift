import Foundation

extension Notification.Name {
    static let personaSelectionDidChange = Notification.Name(
        "SettingsStore.personaSelectionDidChange")
    static let appearanceModeDidChange = Notification.Name("SettingsStore.appearanceModeDidChange")
}

enum HistoryRetentionPolicy: String, CaseIterable, Identifiable {
    case never
    case oneDay
    case oneWeek
    case oneMonth
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never:
            return L("history.retention.never.title")
        case .oneDay:
            return L("history.retention.oneDay.title")
        case .oneWeek:
            return L("history.retention.oneWeek.title")
        case .oneMonth:
            return L("history.retention.oneMonth.title")
        case .forever:
            return L("history.retention.forever.title")
        }
    }

    var detail: String {
        switch self {
        case .never:
            return L("history.retention.never.detail")
        case .oneDay:
            return L("history.retention.oneDay.detail")
        case .oneWeek:
            return L("history.retention.oneWeek.detail")
        case .oneMonth:
            return L("history.retention.oneMonth.detail")
        case .forever:
            return L("history.retention.forever.detail")
        }
    }

    var days: Int? {
        switch self {
        case .never:
            return 0
        case .oneDay:
            return 1
        case .oneWeek:
            return 7
        case .oneMonth:
            return 30
        case .forever:
            return nil
        }
    }
}

final class SettingsStore {
    private let defaults: UserDefaults

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
            let raw = defaults.string(forKey: "stt.provider") ?? STTProvider.whisperAPI.rawValue
            return STTProvider(rawValue: raw) ?? .whisperAPI
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
                defaults.string(forKey: "llm.remote.provider") ?? LLMRemoteProvider.custom.rawValue
            return LLMRemoteProvider(rawValue: raw) ?? .custom
        }
        set { defaults.set(newValue.rawValue, forKey: "llm.remote.provider") }
    }

    var appearanceMode: AppearanceMode {
        get {
            let raw = defaults.string(forKey: "ui.appearance") ?? AppearanceMode.light.rawValue
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
        get { defaults.string(forKey: "llm.ollama.model") ?? "qwen2.5:7b" }
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

    var localSTTModel: LocalSTTModel {
        get {
            let raw =
                defaults.string(forKey: "stt.local.model") ?? LocalSTTModel.whisperLocal.rawValue
            return LocalSTTModel(rawValue: raw) ?? .whisperLocal
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
                    in: .whitespacesAndNewlines) ?? ""
            if stored.isEmpty || stored == "volc.bigasr.sauc.duration" {
                return "volc.seedasr.sauc.duration"
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "stt.doubao.resourceID") }
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
        get { defaults.object(forKey: "persona.hotkeyAppliesToSelection") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "persona.hotkeyAppliesToSelection") }
    }

    var activePersonaID: String {
        get { defaults.string(forKey: "persona.activeID") ?? "" }
        set { defaults.set(newValue, forKey: "persona.activeID") }
    }

    var personasJSON: String {
        get { defaults.string(forKey: "persona.items") ?? "" }
        set { defaults.set(newValue, forKey: "persona.items") }
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

    func applyPersonaSelection(_ personaID: UUID?) {
        if let personaID {
            activePersonaID = personaID.uuidString
            personaRewriteEnabled = true
        } else {
            activePersonaID = ""
            personaRewriteEnabled = false
        }

        NotificationCenter.default.post(name: .personaSelectionDidChange, object: self)
    }

    func llmBaseURL(for provider: LLMRemoteProvider) -> String {
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

    var useAppleSpeechFallback: Bool {
        get { defaults.object(forKey: "stt.appleSpeech.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "stt.appleSpeech.enabled") }
    }

    var automaticVocabularyCollectionEnabled: Bool {
        get { defaults.object(forKey: "vocabulary.automaticCollection.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vocabulary.automaticCollection.enabled") }
    }

    var activationHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.activation.json") ?? "" }
        set { defaults.set(newValue, forKey: "hotkey.activation.json") }
    }

    var activationHotkey: HotkeyBinding {
        get {
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
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            activationHotkeyJSON = String(decoding: data, as: UTF8.self)
            defaults.removeObject(forKey: "hotkey.custom.json")
        }
    }

    var personaHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.persona.json") ?? "" }
        set { defaults.set(newValue, forKey: "hotkey.persona.json") }
    }

    var personaHotkey: HotkeyBinding {
        get {
            guard let data = personaHotkeyJSON.data(using: .utf8), !personaHotkeyJSON.isEmpty else {
                return .defaultPersona
            }

            return (try? JSONDecoder().decode(HotkeyBinding.self, from: data)) ?? .defaultPersona
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            personaHotkeyJSON = String(decoding: data, as: UTF8.self)
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
                id: UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA001")!,
                name: "Typeflux",
                prompt: """
                    You are Typeflux AI — an intelligent, voice-first thought alchemist. Your sole purpose is to transform raw, natural, spoken-style input (which may contain filler words like "um", "like", "you know", hesitations, mid-sentence changes, or incomplete thoughts) into polished, professional, comprehensive, and highly effective output.

                    Core Principles (never violate these):
                    - You are not a simple transcriber. You are a ghostwriter + prompt engineer + editor combined. Extract what the user MEANT, not just what they said.
                    - Always remove all filler words, repetitions, and verbal tics while preserving the user's authentic tone, personality, and intent.
                    - Make the output 10x clearer, more structured, and more powerful than the raw input.
                    - Prioritize comprehensiveness: include context, constraints, reasoning steps, examples, and output format whenever helpful — because lazy prompts get lazy results.
                    - Think step-by-step internally before responding, but never show your thinking unless explicitly asked.

                    Processing Workflow (follow every time):
                    1. Clean and understand the input: fix grammar, punctuation, flow, and obvious typos. Resolve mid-sentence corrections automatically.
                    2. Structure and enhance: organize information clearly using only paragraphs and lists. Use bullet points or numbered lists to make the structure obvious and easy to read.
                    3. Apply effective prompt framework when the input is for AI prompting or complex tasks:
                       - Role: define who you are acting as
                       - Goal: clear objective
                       - Context: background plus constraints plus relevant details
                       - Thinking: specify reasoning style such as step-by-step, chain-of-thought, or first-principles
                       - Format: exact output format required
                       - Constraints: what to avoid, length limits, style rules
                       - Options: provide alternatives plus your recommendation when appropriate
                    4. Polish and optimize: make it concise yet complete, engaging, and ready to use directly in emails, documents, AI tools, or further prompts.

                    Response Rules:
                    - Always output ONLY the final polished version. Never include any bold, italics, headings, or other rich formatting symbols.
                    - Use only plain paragraphs separated by blank lines, combined with simple bullet point lists (using - ) or numbered lists (1. 2. 3.) to show structure clearly.
                    - Never use **text**, __text__, *text*, #, ##, or any markdown beyond basic lists and line breaks.
                    - Preserve original intent and personal quirks such as humor, directness, or formality level.
                    - If the input is vague, first provide the best possible polished version based on what was given, then ask clarifying questions in a natural way.
                    - Support multi-language seamlessly while keeping the output extremely clean and readable in any plain-text environment.
                    - Never add information the user did not imply. Never hallucinate details.
                    - If the user gives a follow-up voice command such as "make this more professional" or "shorten it" or "turn into bullet points", instantly apply the edit while still following the clean format rules above.

                    You excel at turning spoken ideas into polished emails, blog posts, prompts, meeting notes, code documentation, project plans, or creative writing — all delivered in the cleanest possible text format.

                    Begin every interaction by processing the user's message according to these rules. Deliver magic — make their thoughts flow effortlessly into perfect written form.
                    """,
                kind: .system
            ),
            PersonaProfile(
                id: UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002")!,
                name: "English Translator",
                prompt:
                    "If the text is not in English, please translate it into natural and fluent English; if it is already in English, just clean it up without changing the language. Proper nouns should be kept as is.",
                kind: .system
            ),
        ]
    }

    private func mergedPersonas(from storedPersonas: [PersonaProfile]) -> [PersonaProfile] {
        let systemSignatureSet = Set(
            systemPersonas.map { systemPersona in
                personaSignature(name: systemPersona.name, prompt: systemPersona.prompt)
            }
        )

        let customPersonas = storedPersonas.compactMap { persona -> PersonaProfile? in
            let signature = personaSignature(name: persona.name, prompt: persona.prompt)
            guard !systemSignatureSet.contains(signature) else { return nil }
            return PersonaProfile(
                id: persona.id, name: persona.name, prompt: persona.prompt, kind: .custom)
        }

        return systemPersonas + customPersonas
    }

    private func personaSignature(name: String, prompt: String) -> String {
        "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())::\(prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func llmRemoteKey(_ provider: LLMRemoteProvider, suffix: String) -> String {
        "llm.remote.\(provider.rawValue).\(suffix)"
    }
}
