import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ModelPageTabTests {
    @Test func `tabs and domain links`() {
        #expect(ModelPageTab.allCases == [.scenes, .providers, .local])
        #expect(ModelPageTab.providers.id == "providers")
        #expect(ModelPageTab.local.domain == .stt)
        #expect(ModelPageTab.providers.domain == nil)
        #expect(ModelPageTab.scenes.domain == nil)
        #expect(ModelPageTab(domain: .stt) == .providers)
        #expect(ModelPageTab(domain: .llm) == .providers)
        for tab in ModelPageTab.allCases {
            #expect(!tab.title.isEmpty)
        }
    }

    @Test func `tabs reset search and detail without changing scene selection`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = StudioViewModel(
                settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
                initialSection: .models,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            )
            let speech = model.sttProvider
            let language = model.llmProvider
            for tab in ModelPageTab.allCases {
                model.modelSearchQuery = "query"
                model.selectedLanguageProviderID = "openAI"
                model.isShowingSpeechProviderDetail = true
                model.selectModelPageTab(tab)
                #expect(model.modelPageTab == tab)
                #expect(model.modelSearchQuery.isEmpty)
                #expect(!model.isShowingModelProviderDetail)
                #expect(model.selectedLanguageProviderID == nil)
                #expect(model.sttProvider == speech)
                #expect(model.llmProvider == language)
            }
        }
    }

    @Test func domainLinksKeepTheirFocusedDomainInTheSharedProvidersTab() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = SettingsWindowController()
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            defer { controller.window?.close() }
            for domain in StudioModelDomain.allCases {
                controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                                initialSection: .models, initialModelDomain: domain,
                                localModelManager: FixtureLocalModels())
                let model = try #require(controller.viewModel)
                #expect(model.modelPageTab == .providers)
                #expect(model.modelDomain == domain)
                #expect(model.focusedModelProvider.domain == domain)
            }
        }
    }

    @Test func `provider and local tabs support both model domains`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = StudioViewModel(
                settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
                initialSection: .models,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            )
            for tab in [ModelPageTab.providers, .local] {
                model.selectModelPageTab(tab)
                model.selectedLanguageProviderID = "openAI"
                #expect(model.isShowingModelProviderDetail)
                model.selectedLanguageProviderID = "missing"
                #expect(!model.isShowingModelProviderDetail)
                model.focusModelProvider(.whisperAPI)
                model.isShowingSpeechProviderDetail = true
                #expect(model.modelDomain == .stt)
                #expect(model.focusedModelProvider == .whisperAPI)
                #expect(model.isShowingModelProviderDetail)
            }
            model.selectModelPageTab(.scenes)
            model.isShowingSpeechProviderDetail = true
            #expect(!model.isShowingModelProviderDetail)
        }
    }

    @Test func `every page and empty search renders`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = StudioViewModel(
                settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
                initialSection: .models,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            )
            for tab in ModelPageTab.allCases {
                model.selectModelPageTab(tab)
                for query in ["", "no-matching-provider"] {
                    model.modelSearchQuery = query
                    try await SettingsBehaviorTestSupport.withWindow(ModelSettingsPage(
                        viewModel: model,
                        library: model.modelLibrary
                    ) { Text("Speech") }) { _, host in
                        #expect(host.bounds.width > 0)
                    }
                }
            }
        }
    }
}
