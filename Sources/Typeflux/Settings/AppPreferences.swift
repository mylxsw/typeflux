import Foundation

enum AliCloudASRDefaults {
    static let model = "fun-asr-realtime"
}

enum GoogleCloudSpeechDefaults {
    static let model = "chirp_3"
    static let suggestedModels = ["chirp_3", "long", "short", "latest_long", "latest_short"]
}

enum ExperimentalFeatureFlags {
    /// Keep OpenAI Realtime STT behind an explicit flag until the feature is production ready.
    static let openAIRealtimeSTTEnabled = false
}

enum STTProvider: String, CaseIterable, Codable {
    case freeModel
    case whisperAPI
    case appleSpeech
    case localModel
    case multimodalLLM
    case aliCloud
    case doubaoRealtime
    case googleCloud
    case groq
    case typefluxOfficial

    static let defaultProvider: STTProvider = .localModel

    static let settingsDisplayOrder: [STTProvider] = [
        .typefluxOfficial,
        .freeModel,
        .localModel,
        .aliCloud,
        .doubaoRealtime,
        .googleCloud,
        .whisperAPI,
        .multimodalLLM,
        .groq,
    ]

    static let onboardingDisplayOrder: [STTProvider] = settingsDisplayOrder.filter {
        $0 != .typefluxOfficial
    }

    var displayName: String {
        switch self {
        case .freeModel:
            L("provider.stt.freeModel")
        case .whisperAPI:
            L("provider.stt.whisperAPI")
        case .appleSpeech:
            L("provider.stt.appleSpeech")
        case .localModel:
            L("provider.stt.localModel")
        case .multimodalLLM:
            L("provider.stt.multimodalLLM")
        case .aliCloud:
            L("provider.stt.aliCloud")
        case .doubaoRealtime:
            L("provider.stt.doubaoRealtime")
        case .googleCloud:
            L("provider.stt.googleCloud")
        case .groq:
            L("provider.stt.groq")
        case .typefluxOfficial:
            L("provider.stt.typefluxOfficial")
        }
    }

    /// Whether this provider handles persona rewriting internally (no separate LLM rewrite step needed).
    var handlesPersonaInternally: Bool {
        self == .multimodalLLM
    }
}

enum LocalSTTModel: String, CaseIterable, Codable {
    case whisperLocal
    case whisperLocalLarge
    case senseVoiceSmall
    case qwen3ASR

    static let defaultModel: LocalSTTModel = .senseVoiceSmall

    static var displayOrder: [LocalSTTModel] {
        [.senseVoiceSmall, .whisperLocal, .whisperLocalLarge, .qwen3ASR]
    }

    struct Specs {
        let summary: String
        let parameterValue: String
        let sizeValue: String
    }

    var displayName: String {
        switch self {
        case .whisperLocal:
            L("localSTT.whisperLocal.name")
        case .whisperLocalLarge:
            L("localSTT.whisperLocalLarge.name")
        case .senseVoiceSmall:
            L("localSTT.senseVoiceSmall.name")
        case .qwen3ASR:
            L("localSTT.qwen3ASR.name")
        }
    }

    var defaultModelIdentifier: String {
        switch self {
        case .whisperLocal:
            LocalModelDownloadCatalog.whisperKitDefaultModelIdentifier
        case .whisperLocalLarge:
            "whisperkit-large-v3"
        case .senseVoiceSmall:
            // The historical "-coreml" suffix was a misnomer: SenseVoice has always been
            // executed via the sherpa-onnx ONNX runtime, never CoreML. The identifier now
            // matches the directory name shipped under Contents/Resources/BundledModels.
            "sensevoice-small"
        case .qwen3ASR:
            "mlx-community/Qwen3-ASR-0.6B-bf16"
        }
    }

    var recommendedDownloadSource: ModelDownloadSource {
        switch self {
        case .whisperLocal, .whisperLocalLarge:
            .huggingFace
        case .senseVoiceSmall:
            .huggingFace
        case .qwen3ASR:
            .huggingFace
        }
    }

    var recommendationBadgeTitle: String? {
        switch self {
        case .senseVoiceSmall:
            L("settings.models.recommended")
        case .whisperLocal, .whisperLocalLarge, .qwen3ASR:
            nil
        }
    }

    var specs: Specs {
        switch self {
        case .whisperLocal:
            Specs(
                summary: L("localSTT.whisperLocal.summary"),
                parameterValue: L("localSTT.whisperLocal.parameterValue"),
                sizeValue: L("localSTT.whisperLocal.sizeValue"),
            )
        case .whisperLocalLarge:
            Specs(
                summary: L("localSTT.whisperLocalLarge.summary"),
                parameterValue: L("localSTT.whisperLocalLarge.parameterValue"),
                sizeValue: L("localSTT.whisperLocalLarge.sizeValue"),
            )
        case .senseVoiceSmall:
            Specs(
                summary: L("localSTT.senseVoiceSmall.summary"),
                parameterValue: L("localSTT.senseVoiceSmall.parameterValue"),
                sizeValue: L("localSTT.senseVoiceSmall.sizeValue"),
            )
        case .qwen3ASR:
            Specs(
                summary: L("localSTT.qwen3ASR.summary"),
                parameterValue: L("localSTT.qwen3ASR.parameterValue"),
                sizeValue: L("localSTT.qwen3ASR.sizeValue"),
            )
        }
    }
}

enum ModelDownloadSource: String, CaseIterable, Codable {
    case modelScope
    case huggingFace

    var displayName: String {
        switch self {
        case .modelScope:
            L("downloadSource.modelScope")
        case .huggingFace:
            L("downloadSource.huggingFace")
        }
    }
}

enum LLMProvider: String, CaseIterable, Codable {
    case openAICompatible
    case ollama

    var displayName: String {
        switch self {
        case .openAICompatible:
            L("provider.llm.custom")
        case .ollama:
            L("provider.llm.ollama")
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system:
            L("appearance.system")
        case .light:
            L("appearance.light")
        case .dark:
            L("appearance.dark")
        }
    }
}

enum PersonaProfileKind: String, Codable {
    case system
    case custom
}

struct PersonaProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var kind: PersonaProfileKind

    var isSystem: Bool {
        kind == .system
    }

    init(id: UUID = UUID(), name: String, prompt: String, kind: PersonaProfileKind = .custom) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        kind = try container.decodeIfPresent(PersonaProfileKind.self, forKey: .kind) ?? .custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(kind, forKey: .kind)
    }
}

struct PersonaAppBinding: Codable, Identifiable, Equatable {
    let id: UUID
    var appIdentifier: String
    var personaID: UUID

    init(id: UUID = UUID(), appIdentifier: String, personaID: UUID) {
        self.id = id
        self.appIdentifier = appIdentifier
        self.personaID = personaID
    }

    var normalizedAppIdentifier: String {
        Self.normalize(appIdentifier)
    }

    func matches(bundleIdentifier: String?, appName: String?) -> Bool {
        let target = normalizedAppIdentifier
        guard !target.isEmpty else { return false }

        if Self.normalize(bundleIdentifier) == target {
            return true
        }

        if Self.normalize(appName) == target {
            return true
        }

        return false
    }

    static func normalize(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
