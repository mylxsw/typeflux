import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher input history", .exclusiveUIState)
@MainActor
struct AskLauncherInputHistoryTests {
    @MainActor private final class Browser: AskBrowserSearching {
        var started = false
        var fails = false
        func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser],
                      interactive: Bool) async -> AskBrowserSearchSnapshot { .init(entries: []) }
        func focus(_ target: AskBrowserTabTarget) async throws {
            started = true
            try await Task.sleep(for: .milliseconds(100))
            if fails { throw CocoaError(.userCancelled) }
        }
    }

    private final class Storage: AskLauncherInputHistoryStorage {
        var data: Data?
        func read() -> Data? { data }
        func write(_ data: Data) { self.data = data }
    }

    @Test func normalizesDeduplicatesAndReplacesUnsentWithReceipt() {
        var history = AskLauncherInputHistory()
        let date = Date(timeIntervalSince1970: 100)
        history.record("  Query \n", destination: .unsent, at: date)
        let id = history.entries.first?.id
        history.record("other", destination: .askAI)
        history.record("QUERY", destination: .application, label: "Zed", at: date)
        #expect(history.entries.count == 2)
        #expect(history.entries.first?.id == id)
        #expect(history.entries.first?.text == "QUERY")
        #expect(history.entries.first?.destination == .application)
        #expect(history.entries.first?.label == "Zed")
        #expect(history.entries.first?.date == date)
        history.record("query", destination: .unsent)
        #expect(history.entries.first?.destination == .unsent)
    }

    @Test func boundsTextLabelsAndCapacityWithoutBreakingUnicode() {
        var history = AskLauncherInputHistory()
        history.record(" \n ", destination: .askAI)
        history.record("x", destination: .unsent)
        #expect(history.entries.isEmpty)
        history.record("x", destination: .askAI)
        #expect(history.entries.count == 1)
        history.record(String(repeating: "👨‍👩‍👧‍👦", count: 501), destination: .keyword,
                       label: String(repeating: "a", count: 300), keyword: String(repeating: "b", count: 60))
        #expect(history.entries.first?.text.count == 500)
        #expect(history.entries.first?.label.count == 200)
        #expect(history.entries.first?.keyword?.count == 50)
        for index in 0..<210 { history.record("Input \(index)", destination: .askAI, limit: 999) }
        #expect(history.entries.count == 200)
        #expect(history.entries.first?.text == "Input 209")
        history.record("Trim", destination: .askAI, limit: 50)
        #expect(history.entries.count == 50)
        history.record("None", destination: .askAI, limit: -1)
        #expect(history.entries.isEmpty)
    }

    @Test func persistenceFilteringDisablingAndClearing() throws {
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        let storage = Storage()
        storage.data = Data("invalid".utf8)
        let store = AskLauncherInputHistoryStore(settings: settings, storage: storage)
        #expect(store.history.entries.isEmpty)
        store.record("你好世界", destination: .askAI)
        store.record("fy Hello", destination: .keyword, label: "Translate", keyword: "fy")
        let saved = AskLauncherInputHistoryStore(settings: settings, storage: storage)
        #expect(saved.history == store.history)
        #expect(saved.matches("NH").first?.text == "你好世界")
        #expect(saved.matches("nh").first?.text == "你好世界")
        #expect(saved.matches("世界").count == 1)
        #expect(saved.matches(" hello ").count == 1)
        #expect(saved.matches("missing").isEmpty)
        #expect(saved.matches("").count == 2)
        settings.askLauncherInputHistoryEnabled = false
        store.record("Hidden", destination: .askAI)
        #expect(store.matches("").isEmpty)
        #expect(store.history.entries.count == 2)
        settings.askLauncherInputHistoryEnabled = true
        store.delete(try #require(store.history.entries.first?.id))
        #expect(store.history.entries.count == 1)
        store.clear()
        #expect(AskLauncherInputHistoryStore(settings: settings, storage: storage).history.entries.isEmpty)
    }

    @Test func settingsTrimRetainAndClearLocalEntries() async throws {
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        #expect(settings.askLauncherInputHistoryEnabled)
        #expect(settings.askLauncherInputHistoryLimit == 100)
        settings.askLauncherInputHistoryLimit = -1
        #expect(settings.askLauncherInputHistoryLimit == 100)
        settings.defaults.set(0, forKey: "ask.launcher.inputHistory.limit")
        #expect(settings.askLauncherInputHistoryLimit == 100)
        let store = AskLauncherInputHistoryStore(settings: settings)
        for index in 0..<110 { store.record("Input \(index)", destination: .askAI) }
        #expect(store.history.entries.count == 100)
        let view = LauncherSettingsView(settings: settings)
        view.setInputHistoryLimit(50)
        for _ in 0..<10 { await Task.yield() }
        #expect(store.history.entries.count == 50)
        view.setInputHistoryEnabled(false)
        for _ in 0..<10 { await Task.yield() }
        #expect(store.history.entries.count == 50)
        settings.clearLauncherInputHistory()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.history.entries.isEmpty)
    }

    @Test func recallMovesInScreenDirectionFillsAndDeletesWithoutExecuting() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        for text in ["first", "second", "last"] { f.model.recordLauncherInput(destination: .askAI, text: text) }
        let model = f.model
        model.openLauncherInputHistory()
        #expect(model.launcherHistoryMode)
        #expect(model.launcherInputHistoryKey(.up))
        #expect(model.launcherHistoryIndex == 0)
        for _ in 0..<5 { _ = model.launcherInputHistoryKey(.down) }
        #expect(model.launcherHistoryIndex == 2)
        #expect(model.launcherInputHistoryKey(.commandDelete))
        #expect(model.launcherHistoryIndex == 1)
        #expect(model.launcherHistoryEntries.count == 2)
        #expect(!model.launcherInputHistoryKey(.commandY))
        #expect(model.launcherInputHistoryKey(.number(9)))
        #expect(model.launcherHistoryMode)
        #expect(model.launcherInputHistoryKey(.number(1)))
        #expect(model.launcherDraft.text == "last")
        #expect(!model.launcherHistoryMode)
        #expect(!model.launcherInputHistoryKey(.enter))
        #expect(model.busyIds.isEmpty)
        #expect(!model.isOpeningChat)
    }

    @Test(arguments: [AskCommandKey.enter, .right, .tab])
    func fillKeysRecallCurrentInput(key: AskCommandKey) throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.recordLauncherInput(destination: .calculation, label: "= 4", text: "2+2")
        f.model.openLauncherInputHistory()
        #expect(f.model.launcherInputHistoryKey(key))
        #expect(f.model.launcherDraft.text == "2+2")
        #expect(!f.model.launcherHistoryMode)
    }

    @Test func filtersEscapeEmptyBackAndDisabledHistory() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let model = f.model
        model.recordLauncherInput(destination: .askAI, text: "Question")
        model.launcherDraft.text = "typed"
        model.openLauncherInputHistory()
        #expect(!model.launcherHistoryMode)
        model.launcherDraft.text = ""
        model.openLauncherInputHistory()
        model.launcherDraft.text = "missing"
        #expect(model.launcherHistoryEntries.isEmpty)
        _ = model.launcherInputHistoryKey(.enter)
        #expect(model.launcherHistoryMode)
        model.recordAbandonedLauncherInput()
        #expect(model.launcherInputHistory.history.entries.count == 1)
        _ = model.launcherInputHistoryKey(.escape)
        #expect(model.launcherHistoryMode && model.launcherDraft.text.isEmpty)
        _ = model.launcherInputHistoryKey(.escape)
        #expect(!model.launcherHistoryMode)
        model.modelLibrary.settings.askLauncherInputHistoryEnabled = false
        model.openLauncherInputHistory()
        #expect(model.launcherHistoryMode && model.launcherHistoryEntries.isEmpty)
        _ = model.launcherInputHistoryKey(.commandEnter)
        #expect(model.launcherHistoryMode)
        _ = model.launcherInputHistoryKey(.escape)
    }

    @Test func abandonedKeywordPreservesPrefixAndExecutionReceipt() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let keyword = try #require(f.model.launcherKeywords.first { $0.pluginID == AskTranslatePlugin.id })
        f.model.plugins.enter(keyword)
        f.model.launcherDraft.text = "hello"
        f.model.recordAbandonedLauncherInput()
        #expect(f.model.launcherInputHistory.history.entries.first?.text == keyword.keyword + " hello")
        #expect(f.model.launcherInputHistory.history.entries.first?.keyword == keyword.keyword)
        f.model.recordLauncherInput(destination: .keyword, label: "Translate")
        f.model.recordAbandonedLauncherInput()
        #expect(f.model.launcherInputHistory.history.entries.count == 1)
        #expect(f.model.launcherInputHistory.history.entries.first?.destination == .keyword)
        f.model.launcherDraft.text = ""
        f.model.recordLauncherInput(destination: .keyword)
        f.model.recordLauncherInput(destination: .askAI, text: keyword.keyword)
        #expect(f.model.launcherInputHistory.history.entries.count == 1)
    }

    @Test func resetClearsInputToolsAndAttachmentsButCapturesFreshContext() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft = .init(text: "old", selection: "Old selection")
        f.model.launcherDraft.attachments = [.init(kind: .file, name: "Private.txt", text: "Private contents")]
        f.model.launcherDraft.skills = ["old skill"]
        f.model.launcherDraft.mcpServers = ["old server"]
        f.model.launcherHistoryMode = true
        let id = f.model.launcherPresentationID
        f.model.resetLauncherForPresentation()
        #expect(f.model.launcherPresentationID != id)
        #expect(f.model.launcherDraft.text.isEmpty)
        #expect((f.model.launcherDraft.attachments ?? []).isEmpty)
        #expect((f.model.launcherDraft.skills ?? []).isEmpty)
        #expect((f.model.launcherDraft.mcpServers ?? []).isEmpty)
        #expect(!f.model.launcherHistoryMode)
        await f.model.prepareLauncher()
        #expect(f.model.launcherDraft.selection == "Selected words")
        f.model.launcherDraft.text = "typed"
        f.model.persistDrafts()
        try await Task.sleep(for: .milliseconds(350))
        #expect(try await f.cache.draft(key: "launcher", owner: "owner")?.text.isEmpty == true)
        #expect(f.model.launcherDraft.text == "typed")
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func lateAttachmentCannotFillReopenedLauncher() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.addAttachments([.file(URL(fileURLWithPath: "/unused"))], launcher: true) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .init(items: [.init(kind: .file, name: "Old.txt", text: "Old contents")])
        }
        #expect(f.model.isLoadingAttachments(launcher: true))
        f.model.resetLauncherForPresentation()
        #expect(!f.model.isLoadingAttachments(launcher: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.model.attachmentLoads.isEmpty)
        #expect((f.model.launcherDraft.attachments ?? []).isEmpty)
    }

    @Test func quickActionsRecordDestinationsAndFailedFilesKeepInput() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.openApplication = { _ in }
        f.model.launcherDraft.text = "editor"
        let app = AskAppEntry(name: "Zed", url: URL(fileURLWithPath: "/Zed.app"), bundleID: "dev.zed", names: [])
        f.model.openQuickApp(app)
        #expect(f.model.launcherInputHistory.history.entries.first?.destination == .application)
        #expect(f.model.launcherInputHistory.history.entries.first?.label == "Zed")
        #expect(f.model.launcherDraft.text.isEmpty)
        let file = AskFileHit(path: "/gone.txt", name: "gone.txt", kind: .file, modified: Date(), score: 1)
        f.model.launcherDraft.text = "gone"
        f.model.fileExists = { _ in false }
        #expect(f.model.performQuickFileAction(.open, file) == .stay)
        #expect(f.model.launcherDraft.text == "gone")
        #expect(f.model.launcherInputHistory.history.entries.count == 1)
        f.model.fileExists = { _ in true }
        f.model.openURL = { _ in }
        #expect(f.model.performQuickFileAction(.open, file) == .close)
        #expect(f.model.launcherInputHistory.history.entries.first?.destination == .file)
    }

    @Test func commandEnterAsksAIWithInputAndCurrentContext() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.model.prepareLauncher()
        f.model.recordLauncherInput(destination: .unsent, text: "Question")
        f.model.openLauncherInputHistory()
        _ = f.model.launcherInputHistoryKey(.commandEnter)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.sends.first?.text == "Question")
        #expect(await f.api.sends.first?.selection == "Selected words")
        #expect(f.model.launcherInputHistory.history.entries.first?.destination == .askAI)
    }

    @Test(arguments: ["unchanged", "edited", "reopened", "failed"])
    func browserReceiptsUseOriginalInputAndPreserveNewDraft(mode: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let browser = Browser()
        browser.fails = mode == "failed"
        f.model.browserSearch = browser
        f.model.launcherDraft.text = "original tab search"
        let target = AskBrowserTabTarget(browser: .chrome, windowID: "1", tabID: "2", index: 1,
                                         url: "https://example.com")
        let task = Task { await f.model.focusBrowserTab(target) }
        defer { task.cancel() }
        try await f.wait { browser.started }
        if mode == "reopened" { f.model.resetLauncherForPresentation() }
        if mode == "edited" || mode == "reopened" { f.model.launcherDraft.text = "new draft" }
        #expect(await task.value == (mode == "unchanged"))
        if mode == "failed" {
            #expect(f.model.launcherDraft.text == "original tab search")
            #expect(f.model.launcherInputHistory.history.entries.isEmpty)
        } else {
            #expect(f.model.launcherDraft.text == (mode == "unchanged" ? "" : "new draft"))
            #expect(f.model.launcherInputHistory.history.entries.first?.text == "original tab search")
            #expect(f.model.launcherInputHistory.history.entries.first?.destination == .web)
        }
    }

    @Test func fileAttachmentActionKeepsItsSearchInputInHistory() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let file = f.root.appendingPathComponent("notes.txt")
        try "Notes".write(to: file, atomically: true, encoding: .utf8)
        f.model.launcherDraft.text = "find notes"
        f.model.attachFileToLauncher(file)
        try await f.wait { !f.model.isLoadingAttachments(launcher: true) }
        #expect(f.model.launcherDraft.text.isEmpty)
        #expect(f.model.launcherDraft.attachments?.count == 1)
        #expect(f.model.launcherInputHistory.history.entries.first?.text == "find notes")
        #expect(f.model.launcherInputHistory.history.entries.first?.label == "notes.txt")
    }

    @Test func staleHistoryActionsCannotSubmitAnUnrelatedDraft() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.recordLauncherInput(destination: .askAI, text: "Old question")
        f.model.openLauncherInputHistory()
        let entry = try #require(f.model.highlightedLauncherHistory)
        f.model.launcherInputHistory.clear()
        #expect(!f.model.fillLauncherInputHistory(entry))
        f.model.leaveLauncherInputHistory()
        f.model.launcherDraft.text = "Different question"
        f.model.askFromLauncherInputHistory(entry)
        #expect(f.model.launcherDraft.text == "Different question")
        #expect(await f.api.sends.isEmpty)
    }

    @Test func failedPluginAIHandoffDoesNotSaveGeneratedContent() throws {
        let f = try AskTestFixture(authenticated: false)
        defer { f.model.resetSession() }
        let keyword = try #require(f.model.launcherKeywords.first { $0.pluginID == AskTranslatePlugin.id })
        f.model.plugins.enter(keyword)
        f.model.launcherDraft.text = "Original input"
        f.model.askAIFromPlugin("Generated prompt containing the result")
        #expect(f.model.submissionIssues[true] != nil)
        f.model.recordAbandonedLauncherInput()
        #expect(f.model.launcherInputHistory.history.entries.count == 1)
        #expect(f.model.launcherInputHistory.history.entries.first?.text == keyword.keyword + " Original input")
    }

    @Test func closingChainedWorkflowDoesNotRecordItsGeneratedArgument() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let plugin = AskTestPlugin()
        f.model.plugins.replacePlugins([plugin])
        f.model.launcherDraft.text = "Generated argument"
        f.model.plugins.chain(to: plugin.defaultKeywords[0], text: "Generated argument", chain: ["workflow"],
                              selection: nil, language: .english)
        f.model.recordAbandonedLauncherInput()
        f.model.recordLauncherInput(destination: .keyword)
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func pluginRunsRecordTypedArgumentsAndExcludeSelectionsAndChains() async throws {
        let plugin = AskTestPlugin()
        let helper = AskPluginSessionTests()
        let session = helper.session(plugin)
        defer { session.deactivate() }
        var inputs: [String] = []
        session.onRunInput = { keyword, text, title in
            #expect(keyword.keyword == "tt" && title == "Test")
            inputs.append(text)
        }
        session.enter(plugin.defaultKeywords[0])
        session.update(text: "typed", selection: "Private selection", language: .english)
        try await helper.settle(session) { session.output != nil }
        #expect(inputs == ["typed"])
        session.update(text: "", selection: "Private selection", language: .english, runWhenPlanned: true)
        try await helper.settle(session) { session.output?.original == "Private selection" }
        #expect(inputs == ["typed"])
        session.chain(to: plugin.defaultKeywords[0], text: "Generated argument", chain: ["workflow"],
                      selection: nil, language: .english)
        try await helper.settle(session) { session.output?.original == "Generated argument" }
        #expect(inputs == ["typed"])
    }
}
