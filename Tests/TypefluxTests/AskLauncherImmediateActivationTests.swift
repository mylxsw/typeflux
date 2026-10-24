import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskLauncherImmediateActivationTests {
    @Test(arguments: ["search", "directory", "home"])
    func navigationOpensOnce(entry: String) throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for id in [AskSettingsPlugin.id, AskHelpPlugin.id] {
            var opened = 0
            fixture.model.onOpenSettings = { _ in opened += 1 }
            fixture.model.onOpenHelp = { _ in opened += 1 }
            let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.pluginID == id })
            let result = try activate(keyword, entry: entry, fixture: fixture)
            #expect(result == .close)
            #expect(opened == 1)
        }
    }

    @Test(arguments: ["search", "directory", "home"])
    func chatOpensWithoutTransferringSearchLabel(entry: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var opened = 0
        fixture.model.onShowConversation = { opened += 1 }
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.pluginID == AskOpenChatPlugin.id })
        fixture.model.launcherDraft.text = entry == "home" ? "draft body" : "Open Chat"
        let original = fixture.model.launcherDraft
        _ = try activate(keyword, entry: entry, fixture: fixture)
        #expect(!fixture.model.plugins.isActive, "Opening must never enter the chat plugin, even for one frame")
        #expect(fixture.model.launcherDraft == original, "Keep the search visible until the destination accepts it")
        try await fixture.wait { opened == 1 }
        #expect(fixture.model.draft.text == (entry == "home" ? "draft body" : ""))
    }

    @Test(arguments: ["search", "directory", "home"])
    func captureStartsOnceWithChosenMode(entry: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for keyword in AskScreenshotPlugin.keywords + AskScreenshotTextPlugin.keywords {
            var captured: [AskPluginAction.Kind] = []
            fixture.model.onStartScreenshot = { captured.append(.capture(mode: $0, followUp: $1)) }
            let available = try #require(fixture.model.plugins.availableKeywords.first {
                $0.pluginID == keyword.pluginID && $0.options == keyword.options
            })
            #expect(try activate(available, entry: entry, fixture: fixture) == .close)
            try await fixture.wait { !captured.isEmpty }
            #expect(captured == [AskScreenshotPlugin.captureKind(for: keyword)])
        }
    }

    @Test(arguments: [UInt16(36), UInt16(48)], ["chat", "cha", "settings", "help", "jt", "ocr"])
    func selectingInRealEditorOpensWithoutInputPage(key: UInt16, text: String) async throws {
        var opened = 0
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text, prepare: { model in
            model.onShowConversation = { opened += 1 }
            model.onOpenSettings = { _ in opened += 1 }
            model.onOpenHelp = { _ in opened += 1 }
            model.onStartScreenshot = { _, _ in opened += 1 }
        })
        defer { launcher.close() }
        try await launcher.press(key)
        try await launcher.fixture.wait { opened == 1 }
        #expect(!launcher.fixture.model.plugins.isActive)
        #expect(launcher.fixture.model.launcherDraft.text.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func listsAndTextProcessingAreNotImmediateActions() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for keyword in fixture.model.plugins.availableKeywords {
            let immediate = [AskOpenChatPlugin.id, AskSettingsPlugin.id, AskHelpPlugin.id].contains(keyword.pluginID)
                || AskScreenshotPlugin.startsCapture(keyword) || AskSystemCommand(pluginID: keyword.pluginID) != nil
            #expect((fixture.model.launcherImmediateAction(keyword) != nil) == immediate)
        }
    }

    @Test(arguments: ["search", "directory"])
    func listFeaturesPrepareContentWithoutAnotherReturn(entry: String) throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for id in [AskBrowserSearchPlugin.tabsID, AskBrowserSearchPlugin.bookmarksID,
                   AskCalendarPlugin.id, AskWorldClockPlugin.id, AskSystemMonitorPlugin.id, AskSystemInfoPlugin.id] {
            let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.pluginID == id })
            #expect(try activate(keyword, entry: entry, fixture: fixture) == .stay)
            #expect(fixture.model.plugins.keyword == keyword)
            #expect(fixture.model.plugins.request != nil)
        }
    }

    private func activate(_ keyword: AskKeyword, entry: String, fixture: AskTestFixture) throws
        -> AskConversationModel.PluginActionOutcome {
        switch entry {
        case "search":
            let entry = try #require(fixture.model.launcherSearchEntries(language: .english).first { $0.keyword == keyword })
            return fixture.model.enterLauncherSearchEntry(entry, run: true)
        case "directory":
            return fixture.model.performPluginAction(.init(kind: .enterKeyword(keyword.id), title: "", symbol: ""))
        default:
            return fixture.model.enterLauncherKeyword(keyword, run: false)
        }
    }
}
