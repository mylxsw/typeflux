import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask launcher home")
@MainActor
struct AskLauncherHomeTests {
    private typealias Home = AskLauncherHome

    private static let translate = AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)
    private static let translateJapanese = AskKeyword(keyword: "fyja", pluginID: AskTranslatePlugin.id,
                                                      options: [AskTranslatePlugin.targetOption: "ja"])
    private static let dict = AskKeyword(keyword: "dict", pluginID: AskTranslatePlugin.id,
                                         options: [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction])
    private static let polish = AskKeyword(keyword: "rw", pluginID: AskPromptPlugin.id,
                                           options: [AskPromptPlugin.presetOption: "polish"])
    private static let summarize = AskKeyword(keyword: "sum", pluginID: AskPromptPlugin.id,
                                              options: [AskPromptPlugin.presetOption: "summarize"])
    private static let explain = AskKeyword(keyword: "ex", pluginID: AskPromptPlugin.id,
                                            options: [AskPromptPlugin.presetOption: "explain"])
    private static let google = AskKeyword(keyword: "g", pluginID: AskWebSearchPlugin.id,
                                           options: [AskWebSearchPlugin.engineOption: "google"])
    private static let github = AskKeyword(keyword: "gh", pluginID: AskWebSearchPlugin.id,
                                           options: [AskWebSearchPlugin.engineOption: "github"])
    private static let ip = AskKeyword(keyword: "ip", pluginID: AskWorkflowPlugin.idPrefix + "ip")

    private static func choice(_ keyword: AskKeyword) -> Home.KeywordChoice {
        .init(keyword: keyword, title: keyword.keyword.uppercased(), symbol: "star")
    }

    private static let builtIn = [translate, dict, polish, summarize, explain, google, github].map(choice)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(selection: String? = nil, bundle: String? = nil, window: String? = nil,
                         keywords: [Home.KeywordChoice]? = nil, usage: [String: Double] = [:],
                         conversations: [AskConversationSummary] = []) -> Home.Context {
        Home.Context(selection: selection, sourceBundleID: bundle, windowTitle: window, keywords: keywords ?? Self.builtIn,
                     usage: usage, conversations: conversations, now: Self.now)
    }

    private func contextRows(_ sections: [Home.Section]) -> (title: String, subtitle: String?, rows: [Home.Row])? {
        for section in sections {
            if case let .context(title, subtitle, rows) = section { return (title, subtitle, rows) }
        }
        return nil
    }

    private func recentRows(_ sections: [Home.Section]) -> [Home.Row] {
        for section in sections {
            if case let .recent(rows) = section { return rows }
        }
        return []
    }

    private func chips(_ sections: [Home.Section]) -> (chips: [Home.Chip], teaching: Bool)? {
        for section in sections {
            if case let .keywords(chips, teaching) = section { return (chips, teaching) }
        }
        return nil
    }

    private func conversation(_ id: String, title: String? = nil, ago: TimeInterval) -> AskConversationSummary {
        AskConversationSummary(id: id, title: title ?? "Conversation " + id, updatedAt: Self.now.addingTimeInterval(-ago))
    }

    // MARK: - Context section

    @Test func selectedTextOffersItsKeywordsWithThePreview() throws {
        let sections = Home.build(context(selection: "first line\nsecond line", bundle: "com.apple.Notes"))
        let section = try #require(contextRows(sections))
        #expect(section.title == L("ask.home.section.selection", 2))
        #expect(section.subtitle == "“first line second line”")
        #expect(section.rows.map(\.id) == ["text.translate", "text.polish", "text.explain"])
        #expect(section.rows.map(\.keyword) == ["fy", "rw", "ex"])
        #expect(section.rows[0].action == .keyword(Self.translate))
        #expect(section.rows.allSatisfy { $0.title != $0.id && !$0.title.hasPrefix("ask.home") })
    }

    @Test func longSelectionsAreWorthSummarisingAndTheListStaysShort() throws {
        let lines = Array(repeating: "A sentence that goes on.", count: 4).joined(separator: "\n")
        let rows = try #require(contextRows(Home.build(context(selection: lines)))).rows
        #expect(rows.map(\.id) == ["text.translate", "text.summarize", "text.polish", "text.explain"])
        #expect(rows.count == Home.maximumContextRows)
        let long = String(repeating: "word ", count: 50)
        let single = try #require(contextRows(Home.build(context(selection: long)))).rows
        #expect(single.map(\.id).contains("text.summarize"))
    }

    @Test func aSelectedWordIsLookedUpFirst() throws {
        let section = try #require(contextRows(Home.build(context(selection: "  ephemeral \n"))))
        #expect(section.title == L("ask.home.section.word"))
        #expect(section.subtitle == nil)
        #expect(section.rows.map(\.id) == ["word.lookup", "word.examples", "word.explain"])
        #expect(section.rows[0].title == L("ask.home.word.lookup", "ephemeral"))
        #expect(section.rows[0].action == .keyword(Self.translate))
        #expect(section.rows[1].action == .ask(L("ask.home.word.examples.prompt")))
        // Without the keywords only the question is left.
        let bare = try #require(contextRows(Home.build(context(selection: "ephemeral", keywords: []))))
        #expect(bare.rows.map(\.id) == ["word.examples"])
    }

    @Test func codeInAnEditorGetsDeveloperActions() throws {
        let code = "func a() {\n  return 1\n}"
        let section = try #require(contextRows(Home.build(context(selection: code, bundle: "com.apple.dt.Xcode"))))
        #expect(section.title == L("ask.home.section.code", 3))
        #expect(section.rows.map(\.id) == ["code.explain", "code.review", "code.tests"])
        #expect(section.rows[1].action == .ask(L("ask.home.code.review.prompt")))
        #expect(section.rows[2].action == .ask(L("ask.home.code.tests.prompt")))
        let withoutExplain = try #require(contextRows(Home.build(context(selection: code, bundle: "com.jetbrains.goland",
                                                                         keywords: []))))
        #expect(withoutExplain.rows.map(\.id) == ["code.review", "code.tests"])
    }

    @Test func aBrowserWithoutSelectionOffersItsPage() throws {
        let section = try #require(contextRows(Home.build(context(bundle: "com.google.Chrome", window: " Pricing – Linear "))))
        #expect(section.title == L("ask.home.section.page"))
        #expect(section.subtitle == "Pricing – Linear")
        #expect(section.rows.map(\.action) == [.ask(L("ask.home.page.summary.prompt"))])
        let untitled = try #require(contextRows(Home.build(context(bundle: "com.apple.Safari", window: " "))))
        #expect(untitled.subtitle == nil)
        // Browsers Ask cannot read, and other apps, offer nothing for the context.
        #expect(contextRows(Home.build(context(bundle: "org.mozilla.firefox"))) == nil)
        #expect(contextRows(Home.build(context(bundle: "com.tencent.xinWeChat"))) == nil)
        #expect(contextRows(Home.build(context(selection: " \n ", bundle: "com.apple.Notes"))) == nil)
    }

    @Test func textWithNoUsableKeywordOffersNoContextSection() {
        #expect(contextRows(Home.build(context(selection: "one\ntwo", keywords: []))) == nil)
    }

    @Test func keywordLookupPrefersPlainAndUnchangedKeywords() {
        let custom = AskKeyword(keyword: "rw2", pluginID: AskPromptPlugin.id,
                                options: [AskPromptPlugin.presetOption: "polish", AskPromptPlugin.promptOption: "Shout {input}"])
        #expect(Home.promptKeyword(.polish, in: [custom].map(Self.choice)) == nil)
        #expect(Home.promptKeyword(.polish, in: [custom, Self.polish].map(Self.choice))?.keyword == Self.polish)
        #expect(Home.translateKeyword([Self.dict, Self.translateJapanese, Self.translate].map(Self.choice))?.keyword
            == Self.translate)
        #expect(Home.translateKeyword([Self.dict, Self.translateJapanese].map(Self.choice))?.keyword == Self.translateJapanese)
        #expect(Home.translateKeyword([Self.dict].map(Self.choice)) == nil)
    }

    // MARK: - Recent conversations

    @Test func recentConversationsAreFreshNewestFirstAndFitTheSpaceLeft() {
        let conversations = [conversation("old", ago: 2 * 24 * 3600), conversation("b", ago: 3600),
                             conversation("a", ago: 60), conversation("c", ago: 7200), conversation("untitled", title: "", ago: 10),
                             conversation("d", ago: 9000)]
        let alone = recentRows(Home.build(context(conversations: conversations)))
        #expect(alone.map(\.id) == ["conversation.a", "conversation.b", "conversation.c"])
        #expect(alone[0].action == .conversation(id: "a"))
        #expect(alone[0].date == Self.now.addingTimeInterval(-60))
        let beside = recentRows(Home.build(context(selection: "one\ntwo", conversations: conversations)))
        #expect(beside.map(\.id) == ["conversation.a", "conversation.b"])
        let long = Array(repeating: "Line", count: 5).joined(separator: "\n")
        #expect(recentRows(Home.build(context(selection: long, conversations: conversations))).count == 1)
        #expect(recentRows(Home.build(context())).isEmpty)
        #expect(Home.recentBudget(contextRows: 0) == 3)
        #expect(Home.recentBudget(contextRows: 3) == 2)
        #expect(Home.recentBudget(contextRows: 9) == 1)
    }

    // MARK: - Keywords

    @Test func newUsersAreTaughtTheBuiltInKeywords() throws {
        let taught = try #require(chips(Home.build(context(usage: [Self.google.id: 2]))))
        #expect(taught.teaching)
        #expect(taught.chips.map(\.keyword.keyword) == ["fy", "rw", "sum", "g"])
        #expect(chips(Home.build(context(keywords: []))) == nil)
    }

    @Test func usedKeywordsAreRankedByUsageThenTheUsersOrder() throws {
        let keywords = Self.builtIn + [Self.choice(Self.ip)]
        let usage = [Self.ip.id: 5.0, Self.google.id: 1.0, Self.translate.id: 1.0, Self.polish.id: 3.0, "gone": 9.0]
        let ranked = try #require(chips(Home.build(context(keywords: keywords, usage: usage))))
        #expect(!ranked.teaching)
        #expect(ranked.chips.map(\.keyword.keyword) == ["ip", "rw", "fy", "g"])
        #expect(ranked.chips[0].title == "IP")
        let everything = Dictionary(uniqueKeysWithValues: keywords.map { ($0.keyword.id, 1.0) })
        #expect(try #require(chips(Home.build(context(keywords: keywords, usage: everything)))).chips.count
            == Home.maximumChips)
    }

    @Test func anEmptyHomeHasNoSections() {
        #expect(Home.build(context(keywords: [])).isEmpty)
    }

    // MARK: - Navigation

    @Test func theArrowsMoveThroughRowsAndTheChipRowIsOneStop() {
        let sections = Home.build(context(selection: "one\ntwo", conversations: [conversation("a", ago: 60)]))
        let items = Home.items(sections)
        // Three actions, a conversation, four chips.
        #expect(items.count == 8)
        #expect(items.map(\.id).prefix(4) == ["text.translate", "text.polish", "text.explain", "conversation.a"])
        #expect(items[4].id == "chip." + Self.translate.id)
        #expect(Home.move(0, by: 1, in: items) == 1)
        #expect(Home.move(3, by: 1, in: items) == 4)
        #expect(Home.move(6, by: 1, in: items) == 0, "from any chip, ↓ wraps to the first row")
        #expect(Home.move(6, by: -1, in: items) == 3, "from any chip, ↑ goes to the last row")
        #expect(Home.move(0, by: -1, in: items) == 4, "↑ from the first row lands on the chips")
        #expect(Home.move(4, by: 1, in: items, horizontal: true) == 5)
        #expect(Home.move(4, by: -1, in: items, horizontal: true) == 7)
        #expect(Home.move(1, by: 1, in: items, horizontal: true) == 1, "←/→ do nothing on a row")
        #expect(Home.move(42, by: 1, in: items) == 0)
        #expect(Home.move(3, by: 1, in: []) == 0)
        #expect(Home.numberedRows(sections).map(\.id) == ["text.translate", "text.polish", "text.explain", "conversation.a"])
        let rowsOnly = Home.items([.recent(rows: [Home.Row(id: "r", title: "R", symbol: "", tint: .neutral,
                                                            action: .conversation(id: "r"))])])
        #expect(Home.move(0, by: 1, in: rowsOnly) == 0)
    }

    @Test func numberedRowsStopAtNine() {
        let rows = (0 ..< 12).map { Home.Row(id: "\($0)", title: "\($0)", symbol: "", tint: .accent, action: .ask("\($0)")) }
        #expect(Home.numberedRows([.context(title: "", subtitle: nil, rows: rows)]).count == 9)
    }

    @Test func keysMapToTheHomesMoves() {
        typealias Monitor = AskLauncherHomeKeyMonitor
        #expect(Monitor.key(keyCode: AskArrowKeyMonitor.upKeyCode, modifiers: [], characters: nil) == .vertical(-1))
        #expect(Monitor.key(keyCode: AskArrowKeyMonitor.downKeyCode, modifiers: [], characters: nil) == .vertical(1))
        #expect(Monitor.key(keyCode: Monitor.leftKeyCode, modifiers: [], characters: nil) == .horizontal(-1))
        #expect(Monitor.key(keyCode: Monitor.rightKeyCode, modifiers: [.numericPad, .function], characters: nil) == .horizontal(1))
        #expect(Monitor.key(keyCode: 18, modifiers: .command, characters: "1") == .number(1))
        #expect(Monitor.key(keyCode: 25, modifiers: .command, characters: "9") == .number(9))
        #expect(Monitor.key(keyCode: 29, modifiers: .command, characters: "0") == nil)
        #expect(Monitor.key(keyCode: 18, modifiers: [.command, .shift], characters: "1") == nil)
        #expect(Monitor.key(keyCode: 18, modifiers: [], characters: "1") == nil)
        #expect(Monitor.key(keyCode: AskArrowKeyMonitor.upKeyCode, modifiers: .shift, characters: nil) == nil)
        #expect(Monitor.key(keyCode: 36, modifiers: [], characters: "\r") == nil)
    }

    @Test func theBottomBarSaysWhatReturnDoes() {
        let row = { (action: Home.Action) in
            Home.Item.row(Home.Row(id: "r", title: "", symbol: "", tint: .accent, action: action))
        }
        let close = " · " + L("ask.home.hint.close")
        #expect(AskLauncherSuggestions.hint(for: row(.keyword(Self.translate)), hasContext: false)
            == L("ask.home.hint.run") + close)
        #expect(AskLauncherSuggestions.hint(for: row(.ask("q")), hasContext: false) == L("ask.home.hint.ask") + close)
        #expect(AskLauncherSuggestions.hint(for: row(.conversation(id: "c")), hasContext: true)
            == L("ask.home.hint.open") + " · " + L("ask.home.hint.context") + close)
        #expect(AskLauncherSuggestions.hint(for: .chip(Home.Chip(keyword: Self.translate, title: "", symbol: "")),
                                            hasContext: false) == L("ask.home.hint.chip") + close)
        #expect(AskLauncherSuggestions.hint(for: nil, hasContext: false) == L("ask.launcher.hint"))
        #expect(AskLauncherSuggestions.hint(for: nil, hasContext: true) == L("ask.launcher.hint.context"))
        #expect(AskLauncherSuggestions.relative(Self.now.addingTimeInterval(-10), now: Self.now) == L("ask.home.justNow"))
        #expect(!AskLauncherSuggestions.relative(Self.now.addingTimeInterval(-3600), now: Self.now).isEmpty)
        #expect(AskLauncherSuggestions.tint(.neutral) != AskLauncherSuggestions.tint(.accent))
    }

    @Test func heightsAddUpPerSection() {
        let row = Home.Row(id: "r", title: "", symbol: "", tint: .accent, action: .ask(""))
        let base = 1 + AskLauncherSuggestions.listPadding * 2
        #expect(AskLauncherSuggestions.height(for: [.recent(rows: [row])])
            == base + AskLauncherSuggestions.headerHeight + AskLauncherSuggestions.rowHeight)
        #expect(AskLauncherSuggestions.height(for: [.keywords(chips: [], teaching: false)])
            == base + AskLauncherSuggestions.headerHeight + AskLauncherSuggestions.chipRowHeight)
        #expect(AskLauncherSuggestions.typicalHeight > AskVoicePanel.minimumHeight)
    }

    // MARK: - Usage

    @Test func usageDecaysAndKeepsTheMostUsed() {
        var usage = AskKeywordUsage()
        usage.record("fy", at: Self.now)
        usage.record("fy", at: Self.now)
        #expect(usage.scores(at: Self.now)["fy"] == 2)
        let later = Self.now.addingTimeInterval(AskKeywordUsage.halfLife)
        #expect(abs((usage.scores(at: later)["fy"] ?? 0) - 1) < 0.0001)
        usage.record("fy", at: later)
        #expect(abs((usage.scores(at: later)["fy"] ?? 0) - 2) < 0.0001)
        // A clock that went back never makes a score grow by itself.
        #expect(usage.scores(at: Self.now)["fy"] == 2)
        for index in 0 ..< AskKeywordUsage.maximumEntries + 5 { usage.record("k\(index)", at: later) }
        #expect(usage.entries.count == AskKeywordUsage.maximumEntries)
        #expect(usage.entries["fy"] != nil, "the most used keyword stays")
    }

    @Test func usageIsKeptInDefaults() throws {
        let suite = "ask-keyword-usage-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AskKeywordUsageStore(defaults: defaults)
        #expect(store.scores().isEmpty)
        store.record(Self.translate, at: Self.now)
        #expect(AskKeywordUsageStore(defaults: defaults).scores(at: Self.now)[Self.translate.id] == 1)
        defaults.set(Data("not json".utf8), forKey: AskKeywordUsageStore.defaultsKey)
        #expect(AskKeywordUsageStore(defaults: defaults).usage == AskKeywordUsage())
    }

    // MARK: - Model

    private func usageStore() throws -> (AskKeywordUsageStore, UserDefaults, String) {
        let suite = "ask-keyword-usage-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AskKeywordUsageStore(defaults: defaults), defaults, suite)
    }

    @Test func theModelBuildsTheHomeFromTheLauncherDraft() throws {
        let f = try AskTestFixture()
        let (store, defaults, suite) = try usageStore()
        defer { defaults.removePersistentDomain(forName: suite); f.model.resetSession() }
        f.model.keywordUsage = store
        var draft = AskDraft()
        draft.source = "Google Chrome — Pricing – Linear - Google Chrome"
        draft.sourceBundleID = "com.google.Chrome"
        f.model.launcherDraft = draft
        var context = f.model.launcherHomeContext(now: Self.now)
        #expect(context.sourceBundleID == "com.google.Chrome")
        #expect(context.windowTitle == "Pricing – Linear")
        #expect(context.selection == nil)
        #expect(context.keywords.contains { $0.keyword.keyword == "fy" && $0.title == L("ask.plugin.translate.title") })
        #expect(context.keywords.contains { $0.keyword.keyword == "rw" && $0.title == AskPromptPlugin.Preset.polish.title })
        #expect(contextRows(f.model.launcherHome(now: Self.now))?.title == L("ask.home.section.page"))
        // Source switched off: the home no longer knows the app.
        f.model.launcherDraft.sourceOff = true
        context = f.model.launcherHomeContext(now: Self.now)
        #expect(context.sourceBundleID == nil)
        #expect(context.windowTitle == nil)
        // Selection switched off rides with nothing.
        f.model.launcherDraft.selection = "hello world"
        f.model.launcherDraft.selectionOff = true
        #expect(f.model.launcherHomeContext(now: Self.now).selection == nil)
        f.model.launcherDraft.selectionOff = nil
        #expect(f.model.launcherHomeContext(now: Self.now).selection == "hello world")
    }

    @Test func chipTitlesNameTheirPreset() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let language = AppLocalization.shared.language
        let translate = try #require(f.model.plugins.plugin(for: Self.translate))
        #expect(AskConversationModel.chipTitle(plugin: translate, keyword: Self.translate, language: language) == translate.title)
        let japanese = AskConversationModel.chipTitle(plugin: translate, keyword: Self.translateJapanese, language: language)
        #expect(japanese.hasPrefix(translate.title + " → "))
        #expect(AskConversationModel.chipTitle(plugin: translate, keyword: Self.dict, language: language)
            == L("ask.wordBook.title"))
        let web = try #require(f.model.plugins.plugin(for: Self.github))
        #expect(AskConversationModel.chipTitle(plugin: web, keyword: Self.github, language: language) == "GitHub")
    }

    @Test func enteringAKeywordCountsItsUse() throws {
        let f = try AskTestFixture()
        let (store, defaults, suite) = try usageStore()
        defer { defaults.removePersistentDomain(forName: suite); f.model.resetSession() }
        f.model.keywordUsage = store
        f.model.enterLauncherKeyword(Self.polish, run: false)
        #expect(f.model.plugins.keyword == Self.polish)
        #expect((store.scores()[Self.polish.id] ?? 0) > 0.99)
        // Typing a keyword counts too.
        f.model.plugins.deactivate()
        #expect(f.model.plugins.detect(in: "sum hello") == "hello")
        #expect((store.scores()[Self.summarize.id] ?? 0) > 0.99)
        f.model.plugins.deactivate()
    }

    @Test func aQuestionRowSendsWithTheCapturedContext() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        var shown = 0
        f.model.onShowConversation = { shown += 1 }
        f.model.launcherDraft.selection = "func a() {}"
        f.model.askFromLauncherHome(L("ask.home.code.review.prompt"))
        try await f.wait { f.model.busyIds.isEmpty && shown == 1 }
        let send = try #require(await f.api.sends.first)
        #expect(send.text == L("ask.home.code.review.prompt"))
        #expect(send.selection == "func a() {}")
        #expect(f.model.launcherDraft.text.isEmpty)
    }

    @Test func aConversationRowOpensItInTheWorkspace() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.seed(.init(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: []))
        var shown = 0
        f.model.onShowConversation = { shown += 1 }
        f.model.openConversationFromLauncher("a")
        #expect(shown == 1)
        try await f.wait { f.model.selected?.id == "a" }
    }

    @Test func cachedConversationsFillTheHomeWithoutTheNetwork() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setFailList(true)
        try await f.cache.save(.init(id: "cached", title: "Cached", revision: 1, updatedAt: Date(), messages: []),
                               owner: f.sessionState.owner)
        await f.model.loadCachedHistoryIfNeeded()
        #expect(f.model.conversations.map(\.id) == ["cached"])
        #expect(f.model.error == nil, "the network list, which fails here, is never read")
        // Already listed: nothing is read again.
        try await f.cache.save(.init(id: "later", title: "Later", revision: 1, updatedAt: Date(), messages: []),
                               owner: f.sessionState.owner)
        await f.model.loadCachedHistoryIfNeeded()
        #expect(f.model.conversations.map(\.id) == ["cached"])
        #expect(recentRows(f.model.launcherHome()).map(\.title) == ["Cached"])
    }

    @Test func signedOutTheCacheIsLeftAlone() async throws {
        let f = try AskTestFixture(authenticated: false)
        await f.model.loadCachedHistoryIfNeeded()
        #expect(f.model.conversations.isEmpty)
        #expect(f.model.error == nil, "opening the launcher signed out shows no sign-in error")
    }
}
