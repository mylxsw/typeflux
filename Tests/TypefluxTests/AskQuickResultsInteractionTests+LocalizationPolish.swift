import AppKit
import Foundation
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func returnOnSignInFailureOpensLoginWithoutRerunningOrLosingTheDraft() async throws {
        try await withPasteboard { _ in
            let cloudEngine = AskTestTranslationEngine(failure: TypefluxCloudLLMError.notLoggedIn)
            let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false), ai: cloudEngine,
                                            detector: AskTestLanguageDetector(language: "en"))
            let launcher = try await Launcher(text: "fy Hello world", prepare: { model in
                model.plugins = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.fixture.wait { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await launcher.fixture.wait { if case .failed = model.plugins.phase { return true }; return false }
            var signIns = 0
            model.onSignIn = { signIns += 1 }
            let draft = model.launcherDraft
            try await launcher.press(Self.returnKey)
            #expect(signIns == 1 && cloudEngine.requests.count == 1)
            #expect(model.launcherDraft == draft && launcher.dismissed == 0)
        }
    }

    @Test func arrowsAndNumberShortcutsSkipNonExecutableRows() async throws {
        try await withPasteboard { pasteboard in
            let plugin = SkippingPlugin()
            let launcher = try await Launcher(text: "rows list", prepare: { model in
                model.plugins = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.fixture.wait { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await launcher.fixture.wait { model.plugins.output != nil }
            #expect(model.plugins.output?.selectedItem == 1)
            try await launcher.press(18, [.command]) // The first numbered row is disabled.
            #expect(launcher.dismissed == 0 && pasteboard.string(forType: .string) == nil)
            #expect(model.plugins.output?.selectedItem == 1)
            try await launcher.press(Self.down)
            #expect(model.plugins.output?.selectedItem == 3)
            try await launcher.press(Self.up)
            #expect(model.plugins.output?.selectedItem == 1)
            try await launcher.press(Self.up) // Wrap through Ask AI.
            try await launcher.press(Self.up)
            #expect(model.plugins.output?.selectedItem == 3)
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "3" && launcher.dismissed == 1)
        }
    }

    private struct SkippingPlugin: AskLauncherPlugin {
        let id = "skipping"
        let title = "Rows"
        let symbol = "list.bullet"
        var defaultKeywords: [AskKeyword] { [.init(keyword: "rows", pluginID: id)] }
        func placeholder(selectionLines: Int?) -> String { "" }
        func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
        func plan(_ request: AskPluginRequest) async -> AskPluginPlan { .init(mode: .onSubmit, title: title) }
        func run(_ request: AskPluginRequest, plan: AskPluginPlan,
                 progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
            let items: [AskPluginItem] = (0 ..< 5).map { index in
                let title = String(index)
                let action = AskPluginAction(kind: .copy(title), title: "Copy", symbol: "doc", shortcut: .enter)
                return AskPluginItem(id: title, title: title, valid: index % 2 == 1, actions: [action])
            }
            return AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [], items: items)
        }
        func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
    }
}
