import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case home
    case history
    case vocabulary
    case personas
    case models
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("studio.section.home")
        case .models: return L("studio.section.models")
        case .personas: return L("studio.section.personas")
        case .vocabulary: return L("studio.section.vocabulary")
        case .history: return L("studio.section.history")
        case .settings: return L("studio.section.settings")
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
        case .home: return L("studio.eyebrow.home")
        case .models: return L("studio.eyebrow.models")
        case .personas: return L("studio.eyebrow.personas")
        case .vocabulary: return L("studio.eyebrow.vocabulary")
        case .history: return L("studio.eyebrow.history")
        case .settings: return L("studio.eyebrow.settings")
        }
    }

    var heading: String {
        switch self {
        case .home: return L("studio.heading.home")
        case .models: return L("studio.heading.models")
        case .personas: return L("studio.heading.personas")
        case .vocabulary: return L("studio.heading.vocabulary")
        case .history: return L("studio.heading.history")
        case .settings: return L("studio.heading.settings")
        }
    }

    var subheading: String {
        switch self {
        case .home:
            return L("studio.subheading.home")
        case .models:
            return L("studio.subheading.models")
        case .personas:
            return L("studio.subheading.personas")
        case .vocabulary:
            return L("studio.subheading.vocabulary")
        case .history:
            return L("studio.subheading.history")
        case .settings:
            return L("studio.subheading.settings")
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .home: return L("studio.search.home")
        case .models: return L("studio.search.models")
        case .personas: return L("studio.search.personas")
        case .vocabulary: return L("studio.search.vocabulary")
        case .history: return L("studio.search.history")
        case .settings: return L("studio.search.settings")
        }
    }
}

enum StudioModelDomain: String, CaseIterable, Identifiable {
    case stt
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stt: return L("modelDomain.stt.title")
        case .llm: return L("modelDomain.llm.title")
        }
    }

    var subtitle: String {
        switch self {
        case .stt: return L("modelDomain.stt.subtitle")
        case .llm: return L("modelDomain.llm.subtitle")
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
    case aliCloud
    case doubaoRealtime
    case ollama
    case freeModel
    case customLLM
    case openRouter
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case kimi
    case qwen
    case zhipu
    case minimax

    var id: String { rawValue }

    var domain: StudioModelDomain {
        switch self {
        case .appleSpeech, .localSTT, .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return .stt
        case .ollama, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax:
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
    let date: Date
    let timestampText: String
    let sourceName: String
    let previewText: String
    let audioFilePath: String?
    let transcriptText: String?
    let personaPrompt: String?
    let personaResultText: String?
    let selectionOriginalText: String?
    let selectionEditedText: String?
    let pipelineTimingDetails: String?
    let errorMessage: String?
    let applyMessage: String?
    let hasTranscriptToCopy: Bool
    let canRetry: Bool
    let hasFailure: Bool
    let failureMessage: String?
    let accentName: String
    let accentColorName: String
}

struct HistorySection: Identifiable {
    let id: String
    let records: [HistoryPresentationRecord]
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
