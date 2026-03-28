import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case home
    case models
    case personas
    case vocabulary
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Overview"
        case .models: return "Models"
        case .personas: return "Personas"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .models: return "cpu"
        case .personas: return "face.smiling"
        case .vocabulary: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }

    var eyebrow: String {
        switch self {
        case .home: return "VoiceInput"
        case .models: return "Configuration"
        case .personas: return "Voice Personas"
        case .vocabulary: return "Custom Terms"
        case .history: return "Session History"
        case .settings: return "Settings"
        }
    }

    var heading: String {
        switch self {
        case .home: return "Speak naturally, write anywhere."
        case .models: return "Model configuration"
        case .personas: return "Persona library"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var subheading: String {
        switch self {
        case .home:
            return "Keep the whole desktop experience consistent with a calmer, cleaner control surface."
        case .models:
            return "Choose the local and remote engines used for transcription and rewrite flows."
        case .personas:
            return "Create reusable writing styles and keep every prompt ready for daily use."
        case .vocabulary:
            return "Manage the words and names that should be recognized more reliably during dictation."
        case .history:
            return "Review recent sessions, inspect the recognized text, and export your archive."
        case .settings:
            return "Adjust shortcuts, appearance, and behavior from one unified interface."
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .home: return "Search activity..."
        case .models: return "Search models..."
        case .personas: return "Search personas..."
        case .vocabulary: return "Search vocabulary..."
        case .history: return "Search history..."
        case .settings: return "Search settings..."
        }
    }
}

enum StudioModelDomain: String, CaseIterable, Identifiable {
    case stt
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stt: return "Voice Transcription"
        case .llm: return "LLM"
        }
    }

    var subtitle: String {
        switch self {
        case .stt: return "语音转写"
        case .llm: return "大语言模型"
        }
    }

    var iconName: String {
        switch self {
        case .stt: return "waveform"
        case .llm: return "ellipsis.message"
        }
    }
}

enum StudioModelProviderID: String, CaseIterable, Identifiable {
    case appleSpeech
    case localSTT
    case whisperAPI
    case multimodalLLM
    case ollama
    case openAICompatible

    var id: String { rawValue }

    var domain: StudioModelDomain {
        switch self {
        case .appleSpeech, .localSTT, .whisperAPI, .multimodalLLM:
            return .stt
        case .ollama, .openAICompatible:
            return .llm
        }
    }
}

struct StudioModelCard: Identifiable {
    let id: String
    let name: String
    let summary: String
    let badge: String
    let metadata: String
    let isSelected: Bool
    let isMuted: Bool
    let actionTitle: String
}

struct HistoryPresentationRecord: Identifiable {
    let id: UUID
    let timestampText: String
    let sourceName: String
    let previewText: String
    let audioFilePath: String?
    let transcriptText: String?
    let personaPrompt: String?
    let personaResultText: String?
    let selectionOriginalText: String?
    let selectionEditedText: String?
    let errorMessage: String?
    let applyMessage: String?
    let hasTranscriptToCopy: Bool
    let canRetry: Bool
    let hasFailure: Bool
    let failureMessage: String?
    let accentName: String
    let accentColorName: String
}

struct StudioPermissionRowModel: Identifiable, Equatable {
    let id: PrivacyGuard.PermissionID
    let title: String
    let summary: String
    let detail: String
    let isGranted: Bool
    let badgeText: String
    let actionTitle: String
}
