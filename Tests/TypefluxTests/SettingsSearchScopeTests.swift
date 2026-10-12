import Testing
@testable import Typeflux
import TypefluxUI

struct SettingsSearchScopeTests {
    @Test func `list routes and detail routes`() {
        for section in StudioSection.allCases {
            let result = SettingsSearchScope.resolve(section: section, modelTab: .scenes, providerDetail: false,
                                                     agentPane: .overview, launcherPane: .basics)
            switch section {
            case .vocabulary: #expect(result == .vocabulary)
            case .history: #expect(result == .history)
            case .personas: #expect(result == .personas)
            default: #expect(result == nil)
            }
        }
        for tab in ModelPageTab.allCases {
            for detail in [false, true] {
                let result = SettingsSearchScope.resolve(section: .models, modelTab: tab, providerDetail: detail,
                                                         agentPane: .overview, launcherPane: .basics)
                if detail || tab == .scenes {
                    #expect(result == nil)
                } else {
                    #expect(result == (tab == .speech ? .speechModels : .languageModels))
                }
            }
        }
        for pane in AgentSettingsPane.allCases {
            let result = SettingsSearchScope.resolve(section: .agent, modelTab: .scenes, providerDetail: false,
                                                     agentPane: pane, launcherPane: .basics)
            switch pane {
            case .skills: #expect(result == .skills)
            case .memory: #expect(result == .memory)
            case .mcpServers: #expect(result == .mcpServers)
            default: #expect(result == nil)
            }
        }
        for pane in LauncherSettingsPane.allCases {
            let result = SettingsSearchScope.resolve(section: .launcher, modelTab: .scenes, providerDetail: false,
                                                     agentPane: .overview, launcherPane: pane)
            switch pane {
            case .keywords: #expect(result == .keywords)
            case .workflows: #expect(result == .workflows)
            default: #expect(result == nil)
            }
        }
    }

    @Test func `query destinations`() {
        let studio: [SettingsSearchScope] = [.vocabulary, .history, .personas]
        let models: [SettingsSearchScope] = [.speechModels, .languageModels]
        let local: [SettingsSearchScope] = [.skills, .memory, .mcpServers, .keywords, .workflows]
        for scope in studio + models + local {
            #expect(scope.usesStudioQuery == studio.contains(scope))
            #expect(scope.usesModelQuery == models.contains(scope))
        }
    }

    @Test func `native sidebar material matrix`() {
        for style in InterfaceStyle.allCases {
            for reduced in [false, true] {
                for contrasted in [false, true] {
                    for tahoe in [false, true] {
                        let result = TypefluxSidebarMaterial.resolve(style: style, reduceTransparency: reduced,
                                                                     increasedContrast: contrasted,
                                                                     supportsLiquidGlass: tahoe)
                        #expect(result == (reduced || contrasted || (tahoe && style == .classic) ? .opaque : .system))
                    }
                }
            }
        }
    }
}
