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
        let parameterInfo: String
        let sizeInfo: String
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
                parameterInfo: L("localSTT.whisperLocal.parameters"),
                sizeInfo: L("localSTT.whisperLocal.size")
            )
        case .senseVoiceSmall:
            return Specs(
                summary: L("localSTT.senseVoiceSmall.summary"),
                parameterInfo: L("localSTT.senseVoiceSmall.parameters"),
                sizeInfo: L("localSTT.senseVoiceSmall.size")
            )
        case .qwen3ASR:
            return Specs(
                summary: L("localSTT.qwen3ASR.summary"),
                parameterInfo: L("localSTT.qwen3ASR.parameters"),
                sizeInfo: L("localSTT.qwen3ASR.size")
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
            return L("provider.llm.openAICompatible")
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

struct PersonaProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}
