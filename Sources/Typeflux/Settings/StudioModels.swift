import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case home
    case history
    case vocabulary
    case personas
    case models
    case agent
    case settings
    case account

    var id: String {
        rawValue
    }

    /// Sections that appear in the upper sidebar group.
    static var sidebarUpperCases: [StudioSection] {
        [.home, .vocabulary, .history]
    }

    /// Sections that appear in the lower sidebar group.
    static var sidebarLowerCases: [StudioSection] {
        [.models, .personas]
    }

    var title: String {
        switch self {
        case .home: L("studio.section.home")
        case .models: L("studio.section.models")
        case .personas: L("studio.section.personas")
        case .vocabulary: L("studio.section.vocabulary")
        case .history: L("studio.section.history")
        case .agent: L("studio.section.agent")
        case .settings: L("studio.section.settings")
        case .account: L("studio.section.account")
        }
    }

    var iconName: String {
        switch self {
        case .home: "house.fill"
        case .models: "cpu"
        case .personas: "person.crop.rectangle.stack"
        case .vocabulary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        case .agent: "puzzlepiece.extension"
        case .settings: "gearshape.fill"
        case .account: "person.circle"
        }
    }

    var eyebrow: String {
        switch self {
        case .home: L("studio.eyebrow.home")
        case .models: L("studio.eyebrow.models")
        case .personas: L("studio.eyebrow.personas")
        case .vocabulary: L("studio.eyebrow.vocabulary")
        case .history: L("studio.eyebrow.history")
        case .agent: L("studio.eyebrow.agent")
        case .settings: L("studio.eyebrow.settings")
        case .account: L("studio.eyebrow.account")
        }
    }

    var heading: String {
        switch self {
        case .home: L("studio.heading.home")
        case .models: L("studio.heading.models")
        case .personas: L("studio.heading.personas")
        case .vocabulary: L("studio.heading.vocabulary")
        case .history: L("studio.heading.history")
        case .agent: L("studio.heading.agent")
        case .settings: L("studio.heading.settings")
        case .account: L("studio.heading.account")
        }
    }

    var subheading: String? {
        switch self {
        case .home:
            L("studio.subheading.home")
        case .models:
            nil
        case .personas:
            nil
        case .vocabulary:
            L("studio.subheading.vocabulary")
        case .history:
            nil
        case .agent:
            L("studio.subheading.agent")
        case .settings:
            nil
        case .account:
            nil
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .home: L("studio.search.home")
        case .models: L("studio.search.models")
        case .personas: L("studio.search.personas")
        case .vocabulary: L("studio.search.vocabulary")
        case .history: L("studio.search.history")
        case .agent: L("studio.search.agent")
        case .settings: L("studio.search.settings")
        case .account: L("studio.search.account")
        }
    }
}

enum StudioModelDomain: String, CaseIterable, Identifiable {
    case stt
    case llm

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .stt: L("modelDomain.stt.title")
        case .llm: L("modelDomain.llm.title")
        }
    }

    var subtitle: String {
        switch self {
        case .stt: L("modelDomain.stt.subtitle")
        case .llm: L("modelDomain.llm.subtitle")
        }
    }

    var iconName: String {
        switch self {
        case .stt: "waveform"
        case .llm: "ellipsis.message"
        }
    }
}

enum AgentConfigurationTab: String, CaseIterable, Identifiable {
    case general
    case mcpServers

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general:
            L("agent.section.general")
        case .mcpServers:
            L("agent.section.mcpServers")
        }
    }
}

enum StudioModelProviderID: String, CaseIterable, Identifiable {
    case appleSpeech
    case localSTT
    case freeSTT
    case whisperAPI
    case multimodalLLM
    case aliCloud
    case doubaoRealtime
    case googleCloud
    case groqSTT
    case typefluxOfficial
    case typefluxCloud
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
    case grok
    case xiaomi
    case groq
    case openCodeZen
    case openCodeGo

    var id: String {
        rawValue
    }

    var domain: StudioModelDomain {
        switch self {
        case .appleSpeech, .localSTT, .freeSTT, .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime,
             .googleCloud, .groqSTT, .typefluxOfficial:
            .stt
        case .typefluxCloud, .ollama, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek,
             .kimi, .qwen, .zhipu, .minimax, .grok, .xiaomi, .groq, .openCodeZen, .openCodeGo:
            .llm
        }
    }

    var showsManualSaveButton: Bool {
        switch self {
        case .typefluxOfficial, .typefluxCloud:
            false
        default:
            true
        }
    }

    var requiresLoginForConnectionTest: Bool {
        switch self {
        case .typefluxOfficial, .typefluxCloud:
            true
        default:
            false
        }
    }

    var usesExpandedLogo: Bool {
        switch self {
        case .typefluxOfficial, .typefluxCloud:
            true
        case .openCodeZen, .openCodeGo:
            true
        default:
            false
        }
    }

    var usesTypefluxBranding: Bool {
        switch self {
        case .typefluxOfficial, .typefluxCloud:
            true
        default:
            false
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

struct HistoryPipelineStatPresentationItem: Identifiable {
    enum ValueStyle {
        case timestamp
        case duration
    }

    let id: String
    let title: String
    let value: String
    let style: ValueStyle
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
    let pipelineStatItems: [HistoryPipelineStatPresentationItem]
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
