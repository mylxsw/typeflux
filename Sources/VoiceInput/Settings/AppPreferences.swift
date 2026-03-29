import Foundation

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
            return "Whisper API"
        case .appleSpeech:
            return "Apple Speech"
        case .localModel:
            return "Local Model"
        case .multimodalLLM:
            return "Multimodal LLM"
        case .aliCloud:
            return "Alibaba Cloud ASR"
        case .doubaoRealtime:
            return "Doubao Realtime ASR"
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
            return "Whisper Local"
        case .senseVoiceSmall:
            return "SenseVoice Small"
        case .qwen3ASR:
            return "Qwen3-ASR"
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
                summary: "Balanced local ASR with stable English and multilingual dictation, suitable for most offline transcription needs.",
                parameterInfo: "Whisper small, around 244M parameters",
                sizeInfo: "Model file about 460 MB"
            )
        case .senseVoiceSmall:
            return Specs(
                summary: "Fast multilingual speech recognition with strong Mandarin, Cantonese, English, Japanese, and Korean support.",
                parameterInfo: "SenseVoiceSmall, about 234M parameters",
                sizeInfo: "Runtime files usually around 1.1 GB"
            )
        case .qwen3ASR:
            return Specs(
                summary: "Larger multilingual ASR model with stronger context understanding and better long-form recognition quality.",
                parameterInfo: "Qwen3-ASR-0.6B, about 600M parameters",
                sizeInfo: "Runtime files usually around 1.6 GB"
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
            return "ModelScope"
        case .huggingFace:
            return "Hugging Face"
        }
    }
}

enum LLMProvider: String, CaseIterable, Codable {
    case openAICompatible
    case ollama

    var displayName: String {
        switch self {
        case .openAICompatible:
            return "OpenAI-Compatible"
        case .ollama:
            return "Local Ollama"
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
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
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
