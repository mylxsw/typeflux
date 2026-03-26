import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case home
    case models
    case personas
    case history
    case debug
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Overview"
        case .models: return "Models"
        case .personas: return "Personas"
        case .history: return "History"
        case .debug: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .models: return "cpu"
        case .personas: return "face.smiling"
        case .history: return "clock.arrow.circlepath"
        case .debug: return "terminal"
        case .settings: return "gearshape.fill"
        }
    }

    var eyebrow: String {
        switch self {
        case .home: return "VoiceInput"
        case .models: return "Configuration"
        case .personas: return "Voice Personas"
        case .history: return "Session History"
        case .debug: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var heading: String {
        switch self {
        case .home: return "Speak naturally, write anywhere."
        case .models: return "Model configuration"
        case .personas: return "Persona library"
        case .history: return "History"
        case .debug: return "Runtime status"
        case .settings: return "Preferences"
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
        case .history:
            return "Review recent sessions, inspect the recognized text, and export your archive."
        case .debug:
            return "Inspect connectivity, local model state, and recent application errors."
        case .settings:
            return "Adjust shortcuts, appearance, and behavior from one unified interface."
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .home: return "Search activity..."
        case .models: return "Search models..."
        case .personas: return "Search personas..."
        case .history: return "Search history..."
        case .debug: return "Search logs..."
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
    let accentName: String
    let accentColorName: String
}
