import Foundation

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

    var useAppleSpeechFallback: Bool {
        get { defaults.object(forKey: "stt.appleSpeech.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stt.appleSpeech.enabled") }
    }

    var customHotkeyJSON: String {
        get { defaults.string(forKey: "hotkey.custom.json") ?? "[]" }
        set { defaults.set(newValue, forKey: "hotkey.custom.json") }
    }

    var customHotkeys: [HotkeyBinding] {
        get {
            guard let data = customHotkeyJSON.data(using: .utf8) else { return defaultHotkeys }
            let decoded = (try? JSONDecoder().decode([HotkeyBinding].self, from: data)) ?? []
            return decoded.isEmpty ? defaultHotkeys : decoded
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            customHotkeyJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private var defaultHotkeys: [HotkeyBinding] {
        []
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
