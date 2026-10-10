import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case home
    case history
    case vocabulary
    case personas
    case models
    case agent
    case launcher
    case settings
    case account

    var id: String {
        rawValue
    }

    /// Sections that appear in the upper sidebar group.
    static var sidebarUpperCases: [StudioSection] {
        [.home, .vocabulary, .history, .personas, .models, .agent, .launcher]
    }

    /// Sections that appear in the lower sidebar group.
    static var sidebarLowerCases: [StudioSection] {
        []
    }

    var title: String {
        switch self {
        case .home: L("studio.section.home")
        case .models: L("studio.section.models")
        case .personas: L("studio.section.personas")
        case .vocabulary: L("studio.section.vocabulary")
        case .history: L("studio.section.history")
        case .agent: L("studio.section.agent")
        case .launcher: L("studio.section.launcher")
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
        case .launcher: "command"
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
        case .launcher: L("studio.eyebrow.launcher")
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
        case .launcher: L("studio.heading.launcher")
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
        case .launcher:
            nil
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
        case .launcher: L("studio.search.launcher")
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

/// Groups in the Agent settings page's pane list, in display order.
enum AgentSettingsPaneGroup: String, CaseIterable {
    case general
    case capabilities
    case extensions
    case personalization

    /// Caption above the group; the general group has none.
    var title: String? {
        switch self {
        case .general: nil
        case .capabilities: L("agent.group.capabilities")
        case .extensions: L("agent.section.extensions")
        case .personalization: L("agent.group.personalization")
        }
    }
}

/// Panes of the Agent settings page, one per capability, in display order.
enum AgentSettingsPane: String, CaseIterable, Identifiable, SettingsPaneItem {
    case overview
    case webSearch
    case imageGeneration
    case files
    case codeExecution
    case automation
    case skills
    case mcpServers
    case memory

    var id: String {
        rawValue
    }

    var group: AgentSettingsPaneGroup {
        switch self {
        case .overview: .general
        case .webSearch, .imageGeneration, .files, .codeExecution, .automation: .capabilities
        case .skills, .mcpServers: .extensions
        case .memory: .personalization
        }
    }

    /// The capability configured in this pane, whose state the pane list shows.
    var capability: AgentCapability? {
        switch self {
        case .overview, .memory: nil
        case .webSearch: .webSearch
        case .imageGeneration: .imageGeneration
        case .files: .files
        case .codeExecution: .codeExecution
        case .automation: .automation
        case .skills: .skills
        case .mcpServers: .mcpServers
        }
    }

    var title: String {
        switch self {
        case .overview: L("agent.section.overview")
        case .memory: L("agent.section.memory")
        default: capability?.title ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .memory: "brain"
        default: capability?.symbol ?? ""
        }
    }

    /// Panes grouped for the pane list.
    static var sections: [(title: String?, panes: [AgentSettingsPane])] {
        AgentSettingsPaneGroup.allCases.map { group in
            (title: group.title, panes: allCases.filter { $0.group == group })
        }
    }
}

/// Panes of the Launcher settings page, in display order.
enum LauncherSettingsPane: String, CaseIterable, Identifiable, SettingsPaneItem {
    case basics
    case search
    case keywords
    case translation
    case clipboard
    case workflows

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .basics: L("launcher.pane.basics")
        case .search: L("launcher.pane.search")
        case .keywords: L("ask.settings.plugins.title")
        case .translation: L("ask.plugin.translate.title")
        case .clipboard: L("launcher.pane.clipboard")
        case .workflows: L("ask.workflow.section")
        }
    }

    var symbol: String {
        switch self {
        case .basics: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .keywords: "keyboard"
        case .translation: "translate"
        case .clipboard: "doc.on.clipboard"
        case .workflows: "point.3.connected.trianglepath.dotted"
        }
    }

    static var sections: [(title: String?, panes: [LauncherSettingsPane])] {
        [(title: nil, panes: allCases)]
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
    case soniox
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
             .googleCloud, .groqSTT, .soniox, .typefluxOfficial:
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

struct HistoryPipelineRequestPresentationItem: Identifiable {
    let id: String
    let title: String
    let endpoint: String
    let badges: [String]
}

struct HistoryPipelineBadgePresentationItem: Identifiable {
    enum Tone {
        case neutral
        case selected
        case warning
        case failure
    }

    let id: String
    let title: String
    let value: String
    let tone: Tone
}

enum HistoryPipelineTimelineTone {
    case audio
    case realtime
    case transcription
    case cloud
    case local
    case llm
    case apply
}

struct HistoryPipelineTimelinePresentation {
    struct Lane: Identifiable {
        let id: String
        let title: String
        let durationMilliseconds: Int
        let durationText: String
        let offsetFraction: Double
        let widthFraction: Double
        let tone: HistoryPipelineTimelineTone
        let isDetail: Bool
        let isSlowest: Bool
    }

    let totalDurationText: String?
    let timelineSpanDurationText: String?
    let slowestStageText: String?
    let lanes: [Lane]
    let keyMetrics: [HistoryPipelineStatPresentationItem]
    let requestDetails: [HistoryPipelineRequestPresentationItem]
    let summaryBadges: [HistoryPipelineBadgePresentationItem]
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
    let openCCResultText: String?
    let openCCConfig: String?
    let postProcessedText: String?
    let selectionOriginalText: String?
    let selectionEditedText: String?
    let pipelineTimeline: HistoryPipelineTimelinePresentation?
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
