import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher home", .exclusiveUIState)
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

    private func conversation(_ id: String, title: String? = nil, ago: TimeInterval) -> AskConversationSummary {
        AskConversationSummary(id: id, title: title ?? "Conversation " + id, updatedAt: Self.now.addingTimeInterval(-ago))
    }

    @Test func capturedSelectionDoesNotAddOtherHomeSections() {
        let sections = Home.build(context(selection: "first line\nsecond line", bundle: "com.apple.Notes",
                                          conversations: [conversation("a", ago: 60)]))
        #expect(sections.isEmpty)
    }

    // MARK: - Keywords

    @Test func unusedKeywordsFollowTheSessionShuffleAndOneUseAlreadyRanksFirst() throws {
        var input = context()
        input.fallbackKeywordIDs = Self.builtIn.reversed().map { $0.keyword.id }
        let fallback = Home.chips(input)
        #expect(fallback.teaching)
        #expect(fallback.chips.map(\.keyword.id) == Array(input.fallbackKeywordIDs.prefix(Home.maximumChips)))
        input.usage = [Self.translate.id: 1]
        let used = Home.chips(input)
        #expect(!used.teaching)
        #expect(used.chips.first?.keyword == Self.translate)
        #expect(used.chips.count == Home.maximumChips)
        #expect(Home.chips(context(keywords: [])).chips.isEmpty)
    }

    @Test func equalUsageCountsPreferTheMostRecentlyUsedKeyword() throws {
        var input = context(usage: [Self.translate.id: 10, Self.google.id: 10, Self.polish.id: 11])
        input.lastUsed = [Self.translate.id: Self.now, Self.google.id: Self.now.addingTimeInterval(60)]
        let ranked = Home.chips(input)
        #expect(Array(ranked.chips.prefix(3).map(\.keyword.keyword)) == ["rw", "g", "fy"])
    }

    @Test func usedKeywordsAreRankedByUsageThenTheUsersOrder() throws {
        let keywords = Self.builtIn + [Self.choice(Self.ip)]
        let usage = [Self.ip.id: 5.0, Self.google.id: 1.0, Self.translate.id: 1.0, Self.polish.id: 3.0, "gone": 9.0]
        let ranked = Home.chips(context(keywords: keywords, usage: usage))
        #expect(!ranked.teaching)
        #expect(Array(ranked.chips.prefix(4).map(\.keyword.keyword)) == ["ip", "rw", "fy", "g"])
        #expect(ranked.chips[0].title == "IP")
        let everything = Dictionary(uniqueKeysWithValues: keywords.map { ($0.keyword.id, 1.0) })
        #expect(Home.chips(context(keywords: keywords, usage: everything)).chips.count == Home.maximumChips)
    }

    @Test func anEmptyHomeHasNoSections() {
        #expect(Home.build(context(keywords: [])).isEmpty)
    }

    @Test func homeShowsEveryApplicationAndCapsItsVisibleHeight() throws {
        var input = context(conversations: [conversation("a", ago: 60), conversation("b", ago: 120), conversation("c", ago: 180)])
        input.applications = (0 ..< 20).map { AskTestAppIndex.app("App \($0)", id: "test.app.\($0)") }
        let sections = Home.build(input)
        guard case let .applications(apps) = sections.last, sections.count == 2 else {
            Issue.record("Features should appear above the application list")
            return
        }
        #expect(apps.count == input.applications.count)
        #expect(apps.first?.action == .application(input.applications[0]))
        #expect(apps.last?.action == .application(input.applications[19]))
        #expect(Home.items(sections).count == 26)
        #expect(Home.numberedRows(sections).count == 9)
        #expect(AskLauncherSuggestions.height(for: sections) > 480)
        #expect(AskLauncherSuggestions.visibleHeight(for: sections, maximum: 480) == 480)
        #expect(AskLauncherSuggestions.visibleHeight(for: sections, maximum: 0) == 0)
        #expect(Home.move(8, by: 1, in: Home.items(sections)) == 14)
    }

    @Test func fixedFeaturesPrecedeAppsAndRouteToBuiltInDestinations() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        var input = context(keywords: [])
        input.applications = [AskTestAppIndex.app("Notes")]
        let sections = Home.build(input)
        guard case let .features(rows) = sections.first else {
            Issue.record("The built-in feature row must be first")
            return
        }
        #expect(rows.map(\.id) == ["feature.chat", "feature.translate", "feature.screenshot",
                                      "feature.recording", "feature.notes", "feature.wordbook"])
        #expect(rows.first?.title == "Chat")
        let keywords = try rows.map { row in
            guard case let .keyword(keyword) = row.action else {
                throw NSError(domain: "Expected keyword action", code: 1)
            }
            return keyword
        }
        #expect(f.model.launcherImmediateAction(keywords[0])?.kind == .openChat)
        #expect(f.model.launcherImmediateAction(keywords[1]) == nil)
        #expect(f.model.launcherImmediateAction(keywords[2])?.kind == .capture(mode: .region, followUp: .none))
        #expect(f.model.launcherImmediateAction(keywords[3])?.kind == .capture(mode: .recording, followUp: .none))
        #expect(f.model.launcherImmediateAction(keywords[4])?.kind == .openNotes(id: nil))
        #expect(f.model.launcherImmediateAction(keywords[5])?.kind == .openWordBook(key: nil))
        let items = Home.items(sections)
        #expect(Home.move(0, by: 1, in: items) == 6)
        #expect(Home.move(6, by: -1, in: items) == 0)
        #expect(Home.move(0, by: 1, in: items, horizontal: true) == 1)
        #expect(Home.numberedRows(sections).prefix(6).map(\.id) == rows.map(\.id))
        #expect(rows[2].symbol == RingFeature.screenshot.symbol)
        #expect(rows[3].tint == .red)
        for scheme in [ColorScheme.light, .dark] {
            for selected in [false, true] {
                for row in rows {
                    #expect(NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) != nil)
                    let renderer = ImageRenderer(content: AskLauncherFeatureTile(row: row, selected: selected, action: {})
                        .frame(width: 110).environment(\.colorScheme, scheme))
                    #expect(renderer.nsImage != nil)
                }
            }
        }
    }

    // MARK: - Navigation

    @Test func theArrowsMoveThroughRowsAndTheChipRowIsOneStop() {
        let actions = ["translate", "polish", "explain"].map {
            Home.Row(id: "text." + $0, title: $0, symbol: "star", tint: .accent, action: .ask($0))
        }
        let recent: [Home.Section] = [.recent(rows: [Home.Row(id: "conversation.a", title: "A", symbol: "", tint: .neutral,
                                                             action: .conversation(id: "a"))])]
        let sections: [Home.Section] = [.context(title: "Actions", subtitle: nil, rows: actions)] + recent
            + [.keywords(chips: Home.chips(context()).chips, teaching: true)]
        let items = Home.items(sections)
        // Three actions, a conversation, six chips.
        #expect(items.count == 10)
        #expect(items.map(\.id).prefix(4) == ["text.translate", "text.polish", "text.explain", "conversation.a"])
        #expect(items[4].id == "chip." + Self.translate.id)
        #expect(Home.move(0, by: 1, in: items) == 1)
        #expect(Home.move(3, by: 1, in: items) == 4)
        #expect(Home.move(6, by: 1, in: items) == 0, "from any chip, ↓ wraps to the first row")
        #expect(Home.move(6, by: -1, in: items) == 3, "from any chip, ↑ goes to the last row")
        #expect(Home.move(0, by: -1, in: items) == 4, "↑ from the first row lands on the chips")
        #expect(Home.move(4, by: 1, in: items, horizontal: true) == 5)
        #expect(Home.move(4, by: -1, in: items, horizontal: true) == 9)
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
        #expect(AskLauncherSuggestions.hint(for: row(.keyword(Self.translate)), hasContext: false)
            == L("ask.home.hint.run"))
        #expect(AskLauncherSuggestions.hint(for: row(.ask("q")), hasContext: false) == L("ask.home.hint.ask"))
        #expect(AskLauncherSuggestions.hint(for: row(.conversation(id: "c")), hasContext: true)
            == L("ask.home.hint.open") + " · " + L("ask.home.hint.context"))
        #expect(AskLauncherSuggestions.hint(for: .chip(Home.Chip(keyword: Self.translate, title: "", symbol: "")),
                                            hasContext: false) == L("ask.home.hint.chip"))
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
            == base + AskLauncherSuggestions.chipRowHeight)
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
        store.record(Self.translate, at: Self.now.addingTimeInterval(AskKeywordUsage.halfLife * 3))
        #expect(AskKeywordUsageStore(defaults: defaults).usage.entries[Self.translate.id]?.count == 2)
        defaults.set(Data("not json".utf8), forKey: AskKeywordUsageStore.defaultsKey)
        #expect(AskKeywordUsageStore(defaults: defaults).usage == AskKeywordUsage())
    }

    @Test func olderUsageWithoutCountsMigratesAndKeepsRecording() throws {
        let json = Data("{\"entries\":{\"fy\":{\"score\":2.2,\"lastUsed\":0}}}".utf8)
        var usage = try JSONDecoder().decode(AskKeywordUsage.self, from: json)
        #expect(usage.entries["fy"]?.count == 3)
        usage.record("fy", at: Self.now)
        #expect(usage.entries["fy"]?.count == 4)
        #expect(try JSONDecoder().decode(AskKeywordUsage.self, from: JSONEncoder().encode(usage)) == usage)
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
        #expect(contextRows(f.model.launcherHome(now: Self.now)) == nil)
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

    @Test func theModelUsesExactCountsAndAppPreferences() throws {
        let f = try AskTestFixture()
        let (store, defaults, suite) = try usageStore()
        defer { defaults.removePersistentDomain(forName: suite); f.model.resetSession() }
        f.model.keywordUsage = store
        let app = AskTestAppIndex.app("Notes")
        let index = AskTestAppIndex([app])
        f.model.appIndex = index
        store.record(Self.translate, at: Self.now.addingTimeInterval(-AskKeywordUsage.halfLife * 10))
        store.record(Self.translate, at: Self.now.addingTimeInterval(-AskKeywordUsage.halfLife * 9))
        store.record(Self.google, at: Self.now)
        let input = f.model.launcherHomeContext(now: Self.now)
        #expect(input.usage[Self.translate.id] == 2)
        #expect(input.applications == [app])
        #expect(f.model.launcherHomeContext(now: Self.now).fallbackKeywordIDs == input.fallbackKeywordIDs)
        f.model.modelLibrary.settings.askQuickAppSearchEnabled = false
        #expect(f.model.launcherHomeContext(now: Self.now).applications.isEmpty)
        f.model.openApplication = { _ in }
        f.model.openQuickApp(app)
        #expect(index.launched == [app.id])
    }

    @Test func renderFilledHome() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_HOME_SNAPSHOTS"] else { return }
        let f = try AskTestFixture()
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { f.model.resetSession(); AppLocalization.shared.setLanguage(previousLanguage) }
        for (id, title, age) in [("a", "帮我整理这周的工作安排", 600.0), ("b", "解释一下这段代码", 3600.0),
                                 ("c", "写一个简洁的产品介绍", 7200.0)] {
            await f.api.seed(.init(id: id, title: title, revision: 1, updatedAt: Date().addingTimeInterval(-age), messages: []))
        }
        await f.model.refreshHistory()
        let appIDs = ["com.apple.Safari", "com.apple.Notes", "com.apple.Terminal", "com.apple.iCal",
                      "com.apple.calculator", "com.apple.MobileSMS", "com.apple.Music", "com.apple.Photos",
                      "com.apple.reminders", "com.apple.mail", "com.apple.TextEdit", "com.apple.iBooksX"]
        f.model.appIndex = AskTestAppIndex(appIDs.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).flatMap(AskAppIndex.entry(at:))
        })
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance, scheme) in [("dark", NSAppearance.Name.darkAqua, ColorScheme.dark), ("light", .aqua, .light)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let view = NSHostingView(rootView: AskLauncherView(model: f.model, onDismiss: {})
                .preferredColorScheme(scheme))
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("launcher-home-\(name).png"))
        }
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
        #expect(f.model.launcherHome().isEmpty)
    }

    @Test func signedOutTheCacheIsLeftAlone() async throws {
        let f = try AskTestFixture(authenticated: false)
        await f.model.loadCachedHistoryIfNeeded()
        #expect(f.model.conversations.isEmpty)
        #expect(f.model.error == nil, "opening the launcher signed out shows no sign-in error")
    }
}
