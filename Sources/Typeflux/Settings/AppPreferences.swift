import Foundation

enum AliCloudASRDefaults {
    static let model = "fun-asr-realtime"
}

enum STTProvider: String, CaseIterable, Codable {
    case whisperAPI
    case appleSpeech
    case localModel
    case multimodalLLM
    case aliCloud
    case doubaoRealtime

    var displayName: String {
        switch self {
        case .whisperAPI:
            return L("provider.stt.whisperAPI")
        case .appleSpeech:
            return L("provider.stt.appleSpeech")
        case .localModel:
            return L("provider.stt.localModel")
        case .multimodalLLM:
            return L("provider.stt.multimodalLLM")
        case .aliCloud:
            return L("provider.stt.aliCloud")
        case .doubaoRealtime:
            return L("provider.stt.doubaoRealtime")
        }
    }

    /// Whether this provider handles persona rewriting internally (no separate LLM rewrite step needed).
    var handlesPersonaInternally: Bool {
        return self == .multimodalLLM
    }
}

enum LocalSTTModel: String, CaseIterable, Codable {
    case whisperLocal
    case senseVoiceSmall
    case qwen3ASR

    struct Specs {
        let summary: String
        let parameterValue: String
        let sizeValue: String
    }

    var displayName: String {
        switch self {
        case .whisperLocal:
            return L("localSTT.whisperLocal.name")
        case .senseVoiceSmall:
            return L("localSTT.senseVoiceSmall.name")
        case .qwen3ASR:
            return L("localSTT.qwen3ASR.name")
        }
    }

    var defaultModelIdentifier: String {
        switch self {
        case .whisperLocal:
            return "small"
        case .senseVoiceSmall:
            return "iic/SenseVoiceSmall"
        case .qwen3ASR:
            return "Qwen/Qwen3-ASR-0.6B"
        }
    }

    var recommendedDownloadSource: ModelDownloadSource {
        switch self {
        case .whisperLocal:
            return .huggingFace
        case .senseVoiceSmall, .qwen3ASR:
            return .modelScope
        }
    }

    var specs: Specs {
        switch self {
        case .whisperLocal:
            return Specs(
                summary: L("localSTT.whisperLocal.summary"),
                parameterValue: L("localSTT.whisperLocal.parameterValue"),
                sizeValue: L("localSTT.whisperLocal.sizeValue")
            )
        case .senseVoiceSmall:
            return Specs(
                summary: L("localSTT.senseVoiceSmall.summary"),
                parameterValue: L("localSTT.senseVoiceSmall.parameterValue"),
                sizeValue: L("localSTT.senseVoiceSmall.sizeValue")
            )
        case .qwen3ASR:
            return Specs(
                summary: L("localSTT.qwen3ASR.summary"),
                parameterValue: L("localSTT.qwen3ASR.parameterValue"),
                sizeValue: L("localSTT.qwen3ASR.sizeValue")
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
            return L("downloadSource.modelScope")
        case .huggingFace:
            return L("downloadSource.huggingFace")
        }
    }
}

enum LLMProvider: String, CaseIterable, Codable {
    case openAICompatible
    case ollama

    var displayName: String {
        switch self {
        case .openAICompatible:
            return L("provider.llm.custom")
        case .ollama:
            return L("provider.llm.ollama")
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
            return L("appearance.system")
        case .light:
            return L("appearance.light")
        case .dark:
            return L("appearance.dark")
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

    var isSystem: Bool { kind == .system }

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
