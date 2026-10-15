import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskHelpPluginTests {
    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        .init(text: text, origin: origin, keyword: AskHelpPlugin.keywords[0], options: [:], interfaceLanguage: .english)
    }

    @Test func `help opens the guide and searches what follows it, never the selection`() async throws {
        let plugin = AskHelpPlugin()
        #expect(plugin.entersOnReturn && plugin.runsWithoutInput && !plugin.usesSelectionInput)
        #expect(plugin.defaultKeywords[0].allKeywords == ["help", "帮助"])
        let plan = await plugin.plan(request("  截图 "))
        #expect(plan.mode == .onSubmit && plan.action(for: .enter)?.kind == .openHelp(query: "截图"))
        let selected = await plugin.plan(request("Selected words", origin: .selection))
        #expect(selected.action(for: .enter)?.kind == .openHelp(query: ""))
        #expect(!plugin.placeholder(selectionLines: 2).isEmpty && !plugin.title.isEmpty)
        #expect(plugin.chipDetail(for: plugin.defaultKeywords[0], language: .english) == nil)
        #expect(plugin.nextOptions(after: plan, request: request(""), step: 1) == nil)
        do {
            _ = try await plugin.run(request(""), plan: plan)
            Issue.record("help must never run")
        } catch is CancellationError {} catch { Issue.record(error) }
    }

    @Test func `the help keyword is a default keyword and reaches existing users`() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskHelpPlugin.id))
        #expect(AskPluginRegistry.defaultKeywords.contains { $0.pluginID == AskHelpPlugin.id && $0.contains("help") })
        let saved = [AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)]
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskHelpPlugin.id }
        let merged = AskPluginRegistry.keywords(saved: saved, known: known)
        #expect(merged.contains { $0.pluginID == AskHelpPlugin.id }, "a list saved before help existed gains it")
    }

    @Test func `the launcher hands the help action to the app`() async throws {
        let fixture = try AskTestFixture()
        var queries: [String] = []
        fixture.model.onOpenHelp = { queries.append($0) }
        fixture.model.plugins.enter(AskHelpPlugin.keywords[0])
        #expect(fixture.model.performPluginAction(.init(kind: .openHelp(query: "fy"), title: "", symbol: "")) == .close)
        #expect(queries == ["fy"] && !fixture.model.plugins.isActive)
        fixture.model.onOpenHelp = nil
        #expect(fixture.model.performPluginAction(.init(kind: .openHelp(query: ""), title: "", symbol: "")) == .stay)
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func `the help command opens the guide instead of doing nothing`() throws {
        let fixture = try AskTestFixture()
        var queries: [String] = []
        fixture.model.onOpenHelp = { queries.append($0) }
        let command = try #require(AskCommandCatalog.commands(fixture.model.commandContext(launcher: true))
            .first { $0.action == .help })
        fixture.model.runCommand(command, argument: " keywords ", launcher: true)
        fixture.model.runCommand(command, launcher: false)
        #expect(queries == ["keywords", ""])
    }

    @Test func `the guide reads the launcher's keywords with what each works on`() throws {
        let fixture = try AskTestFixture()
        let sources = fixture.model.helpKeywordSources(language: .english)
        let help = try #require(sources.first { $0.entry.keyword.pluginID == AskHelpPlugin.id })
        #expect(!help.usesSelection, "help never takes the selection")
        let translate = try #require(sources.first { $0.entry.keyword.pluginID == AskTranslatePlugin.id })
        #expect(translate.usesSelection && !translate.entry.title.isEmpty)
        let before = fixture.model.helpKeywordUsage[translate.entry.keyword.id] ?? 0
        fixture.model.keywordUsage.record(translate.entry.keyword)
        #expect(fixture.model.helpKeywordUsage[translate.entry.keyword.id] == before + 1)
    }

    @Test func `trying a keyword enters it with the sample typed and runs nothing`() async throws {
        let fixture = try AskTestFixture()
        var shows = 0
        fixture.model.onShowLauncher = { then in shows += 1; then() }
        let available = fixture.model.plugins.availableKeywords
        let translate = try #require(available.first { $0.pluginID == AskTranslatePlugin.id })
        fixture.model.tryKeywordFromHelp(translate, argument: "hello world")
        #expect(shows == 1 && fixture.model.plugins.keyword?.id == translate.id)
        #expect(fixture.model.launcherDraft.text == "hello world")
        #expect(await fixture.api.sends.isEmpty)
        fixture.model.onShowLauncher = nil
        fixture.model.plugins.deactivate()
        fixture.model.tryKeywordFromHelp(translate, argument: "")
        #expect(fixture.model.plugins.keyword?.id == translate.id && fixture.model.launcherDraft.text.isEmpty)
    }

    @Test func `a missing keyword says so after looking for workflows once more`() async throws {
        let fixture = try AskTestFixture()
        fixture.model.onShowLauncher = nil
        let gone = AskKeyword(keyword: "gone", pluginID: AskWorkflowPlugin.idPrefix + "local.gone")
        fixture.model.enterKeywordFromHelp(gone, argument: "", refreshingWorkflows: false)
        #expect(fixture.model.plugins.keyword == nil)
        #expect(fixture.model.commandFeedback == L("hotkeys.keyword.unavailable", "gone"))
    }

    @Test func `the app guide stays visible when opening the launcher trying a sample and asking AI`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try AskTestFixture()
            let ask = AskConversationWindowController(settings: settings, model: fixture.model)
            var settingsLinks: [HelpSettingsDestination] = []
            let guide = HelpWindowController.app(
                settings: settings, ask: ask, openSettings: { settingsLinks.append($0) }, openFeedback: { _ in }
            )
            guide.show(query: "")
            defer {
                fixture.model.resetSession()
                ask.dismissLauncher()
                ask.conversationWindow?.performClose(nil)
                guide.dismiss()
                try? FileManager.default.removeItem(at: fixture.root)
            }
            let window = try #require(guide.presentedWindow)
            guide.model.openSettings(.shortcuts)
            #expect(settingsLinks == [.shortcuts])
            guide.model.openLauncher()
            try await SettingsBehaviorTestSupport.wait { ask.launcherWindow?.isVisible == true }
            #expect(guide.presentedWindow === window && guide.model.isPresented)
            let translate = try #require(guide.model.catalog.keywords.first {
                $0.keyword.pluginID == AskTranslatePlugin.id
            })
            guide.model.showKeyword(translate.id)
            guide.model.tryKeyword(translate, argument: "hello world")
            try await SettingsBehaviorTestSupport.wait { fixture.model.plugins.keyword?.id == translate.keyword.id }
            #expect(fixture.model.launcherDraft.text == "hello world")
            #expect(await fixture.api.sends.isEmpty)
            #expect(guide.presentedWindow === window && guide.model.selectedKeywordID == translate.id)
            guide.model.query = "sync to my phone"
            #expect(guide.model.handle(.commandEnter))
            for _ in 0 ..< 1000 {
                if await !fixture.api.sends.isEmpty { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await fixture.api.sends.last?.text == L("help.askAI.prompt", "sync to my phone"))
            ask.dismissLauncher()
            #expect(guide.presentedWindow === window && guide.model.query == "sync to my phone")
        }
    }

    @Test func `asking the AI from the guide sends the question from the launcher`() async throws {
        let fixture = try AskTestFixture()
        var shows = 0
        fixture.model.onShowLauncher = { then in shows += 1; then() }
        fixture.model.askFromHelp("   ")
        #expect(shows == 0)
        await fixture.model.prepareLauncher()
        fixture.model.askFromHelp(" sync to my phone ")
        #expect(shows == 1)
        for _ in 0 ..< 1000 {
            if await !fixture.api.sends.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.api.sends.last?.text == L("help.askAI.prompt", "sync to my phone"))
    }
}
