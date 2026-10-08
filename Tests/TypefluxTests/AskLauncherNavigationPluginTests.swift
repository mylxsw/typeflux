import Foundation
import Testing
@testable import Typeflux

@Suite("Launcher settings and chat history", .serialized)
@MainActor
struct AskLauncherNavigationPluginTests {
    private func request(_ keyword: AskKeyword, text: String = "", origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        .init(text: text, origin: origin, keyword: keyword, options: [:], interfaceLanguage: .english)
    }

    @Test func settingIsAnExplicitApplicationSettingsAction() async throws {
        let plugin = AskSettingsPlugin()
        let input = request(plugin.defaultKeywords[0])
        let plan = await plugin.plan(input)
        #expect(plugin.entersOnReturn && plugin.runsWithoutInput && !plugin.usesSelectionInput)
        #expect(plan.mode == .onSubmit && plan.action(for: .enter)?.kind == .openSettings)
        #expect(!plugin.placeholder(selectionLines: 3).isEmpty)
        #expect(plugin.chipDetail(for: input.keyword, language: .english) == nil)
        #expect(plugin.nextOptions(after: plan, request: input, step: 1) == nil)
        do { _ = try await plugin.run(input, plan: plan) ; Issue.record("Settings must never execute inference") }
        catch is CancellationError {} catch { Issue.record(error) }
        let f = try AskTestFixture()
        var sections: [StudioSection] = []
        f.model.onOpenSettings = { sections.append($0) }
        f.model.plugins.enter(plugin.defaultKeywords[0])
        f.model.launcherDraft = AskDraft(text: "Ignored text", selection: "Captured text")
        #expect(f.model.performPluginAction(plan.action(for: .enter)!) == .close)
        #expect(sections == [.settings] && !f.model.plugins.isActive && f.model.launcherDraft.text.isEmpty)
        #expect(await f.api.sends.isEmpty)
        f.model.onOpenSettings = nil
        #expect(f.model.performPluginAction(plan.action(for: .enter)!) == .stay)
    }

    @Test func historyFiltersChineseAndEnglishTitlesAndShowsNewestFirst() async throws {
        let rows: [AskConversationSummary] = [
            .init(id: "old", title: "Project planning", updatedAt: Date(timeIntervalSince1970: 1)),
            .init(id: "new", title: "PROJECT notes", updatedAt: Date(timeIntervalSince1970: 3)),
            .init(id: "chinese", title: "项目设计", updatedAt: Date(timeIntervalSince1970: 2))
        ]
        let plugin = AskHistoryPlugin(conversations: { .init(account: "owner", conversations: rows) })
        var input = request(plugin.defaultKeywords[0], text: "  project ")
        let plan = await plugin.plan(input)
        #expect(plugin.entersOnReturn && plugin.runsWithoutInput && !plugin.usesSelectionInput && plan.mode == .live)
        let output = try await plugin.run(input, plan: plan)
        #expect(output.items.map(\.id) == ["new", "old"])
        #expect(output.items[0].actions.first?.kind == .openConversation("new", account: "owner"))
        #expect(output.items[0].actions.first?.shortcut == .enter)
        input.text = "项目"
        #expect(try await plugin.run(input, plan: plan).items.map(\.id) == ["chinese"])
        input.text = "missing"
        let empty = try await plugin.run(input, plan: plan)
        #expect(empty.items.isEmpty && empty.body == L("ask.plugin.history.noMatch"))
        input.origin = .selection
        #expect(try await plugin.run(input, plan: plan).items.count == 3)
        #expect(plugin.nextOptions(after: plan, request: input, step: 1) == nil)
        #expect(!plugin.placeholder(selectionLines: 2).isEmpty)
    }

    @Test func historyCombinesAccountCacheLocalChatsAndListedTitlesWithoutNetworking() async throws {
        let f = try AskTestFixture()
        let cache = f.cache
        try await cache.save(.init(id: "cloud", title: "Cached", revision: 1, updatedAt: Date(timeIntervalSince1970: 1), messages: []), owner: "owner")
        try await cache.save(.init(id: "private", title: "Local chat", revision: 1, updatedAt: Date(timeIntervalSince1970: 2), messages: []), owner: AskRoutedAPI.localOwner)
        try await cache.save(.init(id: "foreign", title: "Other account", revision: 1, updatedAt: Date(), messages: []), owner: "other")
        _ = f.model.credentials()
        await f.api.setListed([.init(id: "cloud", title: "New title", updatedAt: Date(timeIntervalSince1970: 3))])
        await f.model.refreshHistory()
        await f.api.setFailList(true)
        await f.localAPI.setFailList(true)
        let snapshot = await f.model.launcherChatHistory()
        #expect(snapshot.account == "owner" && snapshot.conversations.map(\.id) == ["cloud", "private"])
        #expect(snapshot.conversations.first?.title == "New title")
        #expect(f.model.isLocal("private") && f.model.error == nil)
        #expect(await f.api.sends.isEmpty)
        f.sessionState.owner = "other"
        #expect(await f.model.launcherChatHistory().conversations.isEmpty)
    }

    @Test func firstHistoryQueryPreservesLauncherAndWorkspaceDrafts() async throws {
        let f = try AskTestFixture()
        f.model.launcherDraft = AskDraft(text: "history Project", selection: "Selected")
        f.model.draft.text = "Unsent workspace draft"
        _ = await f.model.launcherChatHistory()
        #expect(f.model.launcherDraft.text == "history Project")
        #expect(f.model.launcherDraft.selection == "Selected" && f.model.draft.text == "Unsent workspace draft")
        #expect(f.model.owner == "owner")
        let signedOut = try AskTestFixture(authenticated: false)
        try await signedOut.cache.save(.init(id: "stale", title: "Old account", revision: 1, updatedAt: Date(), messages: []), owner: "owner")
        #expect(await signedOut.model.launcherChatHistory().conversations.isEmpty)
        #expect(signedOut.model.error == nil)
    }

    @Test func openingHistoryRoutesLocalConversationAndDoesNotSendAQuestion() async throws {
        let f = try AskTestFixture()
        let conversation = AskConversation(id: "private", title: "Local", revision: 1, updatedAt: Date(), messages: [])
        try await f.cache.save(conversation, owner: AskRoutedAPI.localOwner)
        await f.localAPI.seed(conversation)
        _ = await f.model.launcherChatHistory()
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        f.model.launcherDraft = AskDraft(text: "Local", selection: "Ignore selection")
        let action = AskPluginAction(kind: .openConversation("private", account: "owner"), title: "", symbol: "")
        #expect(f.model.performPluginAction(action) == .close)
        try await f.wait { f.model.selected?.id == "private" && !f.model.isLoadingSelection }
        #expect(opens == 1 && f.model.error == nil)
        #expect(f.model.draft.selection == nil)
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
        f.sessionState.owner = "other"
        #expect(f.model.performPluginAction(action) == .stay && opens == 1)
    }

    @Test func settingsAndHistoryMigrateWithoutOverwritingExistingNames() {
        let newIDs = [AskSettingsPlugin.id, AskHistoryPlugin.id]
        let previous = AskPluginRegistry.defaultKeywords.filter { !newIDs.contains($0.pluginID) }
        let covered = AskPluginRegistry.coveredGroups.filter { !newIDs.contains($0) }
        #expect(AskPluginRegistry.keywords(saved: previous, known: covered)
            == previous + AskSettingsPlugin.keywords + AskHistoryPlugin.keywords)
        let custom = AskKeyword(keyword: "SETTING", pluginID: AskWebSearchPlugin.id)
        let migrated = AskPluginRegistry.keywords(saved: previous + [custom], known: covered, reserved: ["history"])
        #expect(migrated == previous + [custom])
        for keyword in AskSettingsPlugin.keywords + AskHistoryPlugin.keywords {
            #expect(AskKeywordMatcher.match(keyword.keyword + "more", keywords: [keyword]) == nil)
            let editor = AskKeywordDraft(editing: keyword)
            #expect(editor.fieldProblem == nil && editor.result() == keyword)
            #expect(editor.displayName == AskKeywordKind(pluginID: keyword.pluginID)?.title)
        }
    }
}
