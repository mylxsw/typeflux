import Foundation

/// Search is available only where the displayed content can be filtered.
enum SettingsSearchScope: Equatable {
    case vocabulary, history, personas, speechModels, languageModels, skills, memory, mcpServers, keywords, workflows

    static func resolve(section: StudioSection, modelTab: ModelPageTab, providerDetail: Bool,
                        agentPane: AgentSettingsPane, launcherPane: LauncherSettingsPane) -> Self? {
        switch section {
        case .vocabulary: .vocabulary
        case .history: .history
        case .personas: .personas
        case .models:
            providerDetail || modelTab == .scenes ? nil : modelTab == .local ? .speechModels : .languageModels
        case .agent: agentScope(agentPane)
        case .launcher: launcherScope(launcherPane)
        default: nil
        }
    }

    private static func agentScope(_ pane: AgentSettingsPane) -> Self? {
        switch pane {
        case .skills: .skills
        case .memory: .memory
        case .mcpServers: .mcpServers
        default: nil
        }
    }

    private static func launcherScope(_ pane: LauncherSettingsPane) -> Self? {
        switch pane {
        case .keywords: .keywords
        case .workflows: .workflows
        default: nil
        }
    }

    var usesModelQuery: Bool {
        self == .speechModels || self == .languageModels
    }

    var usesStudioQuery: Bool {
        [.vocabulary, .history, .personas].contains(self)
    }
}
