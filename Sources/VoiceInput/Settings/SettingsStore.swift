import Foundation

extension Notification.Name {
    static let personaSelectionDidChange = Notification.Name("SettingsStore.personaSelectionDidChange")
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
            return "Never"
        case .oneDay:
            return "24 hours"
        case .oneWeek:
            return "1 week"
        case .oneMonth:
            return "1 month"
        case .forever:
            return "Forever"
        }
    }

    var detail: String {
        switch self {
        case .never:
            return "Do not retain local history after each session."
        case .oneDay:
            return "Automatically remove entries older than one day."
        case .oneWeek:
            return "Keep the latest seven days of dictation history."
        case .oneMonth:
            return "Keep the latest thirty days of dictation history."
        case .forever:
            return "Keep all local history until you remove it manually."
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
    private let defaults = UserDefaults.standard

    var sttProvider: STTProvider {
        get {
            let raw = defaults.string(forKey: "stt.provider") ?? STTProvider.whisperAPI.rawValue
            return STTProvider(rawValue: raw) ?? .whisperAPI
        }
        set { defaults.set(newValue.rawValue, forKey: "stt.provider") }
    }

    var llmProvider: LLMProvider {
        get {
            let raw = defaults.string(forKey: "llm.provider") ?? LLMProvider.openAICompatible.rawValue
            return LLMProvider(rawValue: raw) ?? .openAICompatible
        }
        set { defaults.set(newValue.rawValue, forKey: "llm.provider") }
    }

    var appearanceMode: AppearanceMode {
        get {
            let raw = defaults.string(forKey: "ui.appearance") ?? AppearanceMode.light.rawValue
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: "ui.appearance") }
    }

    var preferredMicrophoneID: String {
        get { defaults.string(forKey: "audio.input.preferredMicrophoneID") ?? AudioDeviceManager.automaticDeviceID }
        set { defaults.set(newValue, forKey: "audio.input.preferredMicrophoneID") }
    }

    var muteSystemOutputDuringRecording: Bool {
        get { defaults.object(forKey: "audio.recording.muteSystemOutput") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "audio.recording.muteSystemOutput") }
    }

    var historyRetentionPolicy: HistoryRetentionPolicy {
        get {
            let raw = defaults.string(forKey: "history.retentionPolicy") ?? HistoryRetentionPolicy.oneWeek.rawValue
            return HistoryRetentionPolicy(rawValue: raw) ?? .oneWeek
        }
        set { defaults.set(newValue.rawValue, forKey: "history.retentionPolicy") }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: "llm.baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "llm.baseURL") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llm.model") ?? "" }
        set { defaults.set(newValue, forKey: "llm.model") }
    }

    var llmAPIKey: String {
        get { defaults.string(forKey: "llm.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "llm.apiKey") }
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
            let raw = defaults.string(forKey: "stt.local.model") ?? LocalSTTModel.whisperLocal.rawValue
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
            let raw = defaults.string(forKey: "stt.local.downloadSource") ?? localSTTModel.recommendedDownloadSource.rawValue
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
            let stored = defaults.string(forKey: "stt.doubao.resourceID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            guard let data = personasJSON.data(using: .utf8), !personasJSON.isEmpty else { return defaultPersonas }
            let decoded = (try? JSONDecoder().decode([PersonaProfile].self, from: data)) ?? []
            return decoded.isEmpty ? defaultPersonas : decoded
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
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

    var useAppleSpeechFallback: Bool {
        get { defaults.object(forKey: "stt.appleSpeech.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stt.appleSpeech.enabled") }
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

            guard let data = activationHotkeyJSON.data(using: .utf8), !activationHotkeyJSON.isEmpty else {
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

    private var defaultPersonas: [PersonaProfile] {
        [
            PersonaProfile(
                name: "专业助理",
                prompt: "使用专业、清晰、简洁的中文表达，整理语序，保留关键信息，适合直接发给同事或客户。"
            ),
            PersonaProfile(
                name: "社媒达人",
                prompt: "改写成更有感染力和分享感的中文内容，语气自然、鲜活，适合社交媒体发布。"
            )
        ]
    }
}
