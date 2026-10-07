import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask word book export")
struct AskWordBookExporterTests {
    private func entry(_ lookup: AskWordBookLookup, count: Int = 1, starred: Date? = nil) -> AskWordBookEntry {
        AskWordBookEntry(id: UUID(), lookup: lookup, lookupCount: count, firstLookedUpAt: Date(timeIntervalSince1970: 0),
                         lastLookedUpAt: Date(timeIntervalSince1970: 0), starredAt: starred)
    }

    private var card: AskWordBookEntry {
        entry(AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard),
              count: 3, starred: Date(timeIntervalSince1970: 0))
    }

    private var plain: AskWordBookEntry {
        entry(AskWordBookLookup(headword: "say \"hi\", now", source: nil, target: "zh-Hans", translation: "说\n嗨"))
    }

    @Test func csvQuotesWhatNeedsIt() {
        let csv = AskWordBookExporter.export([card, plain], as: .csv)
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[0] == "headword,phonetic,meanings,source,target,count,starred_at")
        #expect(lines[1] == "serendipity,/ˌserənˈdɪpəti/,n. 机缘巧合；意外的好运  adj. 偶然的,en,zh-Hans,3,1970-01-01T00:00:00Z")
        #expect(csv.contains("\"say \"\"hi\"\", now\",,\"说\n嗨\",,zh-Hans,1,"))
        #expect(AskWordBookExporter.csvField("plain") == "plain")
    }

    @Test func markdownUsesTheCardsCopyFormat() {
        let markdown = AskWordBookExporter.export([card, plain], as: .markdown)
        #expect(markdown.hasPrefix(wordBookCard.markdown))
        #expect(markdown.contains("\n\n---\n\n**say \"hi\", now**\n说\n嗨"))
    }

    @Test func ankiPutsTheWordInFrontAndMeaningsBehind() {
        let anki = AskWordBookExporter.export([card, plain], as: .anki)
        let lines = anki.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "serendipity /ˌserənˈdɪpəti/\tn. 机缘巧合；意外的好运  adj. 偶然的<br>Pure serendipity. — 纯属巧合。")
        #expect(lines[1] == "say \"hi\", now\t说<br>嗨")
        #expect(AskWordBookExporter.ankiField("a\tb\r\nc") == "a b<br>c")
    }

    @Test func formatsNameTheirFiles() {
        #expect(AskWordBookExporter.Format.allCases.map(\.fileExtension) == ["csv", "md", "tsv"])
        #expect(AskWordBookExporter.Format.allCases.allSatisfy { !$0.title.isEmpty && $0.id == $0.rawValue })
    }
}

/// A dictionary that fails.
final class AskFailingWordLookup: AskWordLookingUp, @unchecked Sendable {
    func lookUp(_ text: String, from source: String?, to target: String, generation: String) async throws -> AskWordLookup {
        throw AskPluginFailure(message: "offline")
    }
}

@Suite("Ask word book window model", .serialized)
@MainActor
struct AskWordBookViewModelTests {
    /// Friday 15 January 2027, 08:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> (AskWordBookViewModel, SQLiteAskWordBookStore, SettingsStore, String) {
        let store = makeTestWordBook()
        let suite = "wordbook-dialog-\(UUID().uuidString)"
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let words: [(String, Double, Bool)] = [("alpha", 0, true), ("beta", 1, false), ("gamma", 3, true),
                                                ("delta", 10, false), ("epsilon", 40, false)]
        for (word, daysAgo, starred) in words {
            let lookup = AskWordBookLookup(headword: word, source: "en", target: "zh-Hans", translation: word + " 义")
            store.record(lookup, at: Self.now.addingTimeInterval(-daysAgo * 86400), counts: true)
            if starred { store.setStarred(true, lookup: lookup, at: Self.now.addingTimeInterval(-daysAgo * 86400)) }
        }
        let model = AskWordBookViewModel(store: store, settings: settings)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        model.calendar = calendar
        model.now = { Self.now }
        model.detector = AskTestLanguageDetector(language: "en")
        model.interfaceLanguage = { .simplifiedChinese }
        model.onDevice = AskTestTranslationEngine(available: false)
        model.reload()
        return (model, store, settings, suite)
    }

    private func key(_ word: String) -> String { AskWordBookEntry.key(headword: word, source: "en", target: "zh-Hans") }
    private let pair = AskWordBookLanguagePair(source: "en", target: "zh-Hans")

    @Test func opensOnAllWordsWithShelfCountsAndActivity() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(model.shelf == .all)
        #expect(model.entries.map(\.headword) == ["alpha", "beta", "gamma", "delta", "epsilon"])
        #expect(model.selectedKey == key("alpha"))
        #expect(model.counts[.all] == 5 && model.counts[.starred] == 2 && model.counts[.today] == 1)
        #expect(model.counts[.week] == 3 && model.counts[.pair(pair)] == 5 && model.weekTotal == 3)
        #expect(model.sections.map(\.period) == [.today, .yesterday, .week, .month, .earlier])
        #expect(model.streak == 2, "today and yesterday")
        #expect(model.week == [0, 2, 0, 2, 2, 0, 0], "Tuesday, Thursday and Friday, Monday first")
        #expect(model.pairs == [pair])
        for shelf in [AskWordBookViewModel.Shelf.all, .starred, .today, .week, .pair(pair)] {
            #expect(!model.title(of: shelf).isEmpty)
        }
    }

    @Test func shelvesFilterAndSort() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.shelf = .starred
        #expect(model.entries.map(\.headword) == ["alpha", "gamma"])
        model.shelf = .today
        #expect(model.entries.map(\.headword) == ["alpha"])
        model.shelf = .week
        #expect(model.entries.map(\.headword) == ["alpha", "beta", "gamma"])
        model.shelf = .pair(pair)
        #expect(model.entries.count == 5)
        model.shelf = .pair(AskWordBookLanguagePair(source: "ja", target: "en"))
        #expect(model.shelf == .all, "a direction with no words falls back to all")
        model.sort = .alphabetical
        #expect(model.sections.map(\.period) == [nil])
        #expect(model.entries.map(\.headword) == ["alpha", "beta", "delta", "epsilon", "gamma"])
        model.filterText = "zzz"
        #expect(model.sections.isEmpty && model.selected == nil && model.displayed == nil)
        #expect(model.counts[.all] == 5, "the counts ignore the filter")
    }

    @Test func periodsFollowTheCalendar() {
        let now = Self.now
        #expect(AskWordBookViewModel.Period.of(now, now: now) == .today)
        #expect(AskWordBookViewModel.Period.of(now.addingTimeInterval(86400), now: now) == .today)
        #expect(AskWordBookViewModel.Period.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func revealingAWordShowsItWhereItLives() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.shelf = .starred
        model.filterText = "alp"
        model.reveal(key("delta"))
        #expect(model.shelf == .all && model.filterText.isEmpty && model.selectedKey == key("delta"))
        model.shelf = .starred
        model.reveal(key("gamma"))
        #expect(model.shelf == .starred && model.selected?.headword == "gamma")
        model.reveal("unknown")
        model.reveal(nil)
        #expect(model.selectedKey == key("gamma"))
    }

    @Test func arrowsMoveThroughTheList() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.moveSelection(1)
        #expect(model.selected?.headword == "beta")
        model.moveSelection(10)
        #expect(model.selected?.headword == "epsilon")
        model.moveSelection(-1)
        #expect(model.selected?.headword == "delta")
        model.selectedKey = nil
        model.moveSelection(1)
        #expect(model.selected?.headword == "alpha")
        model.filterText = "zzz"
        model.moveSelection(1)
        #expect(model.selected == nil)
    }

    // MARK: Looking up

    @Test func aWordWithAKeptCardOpensWithoutAskingTheAI() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let kept = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard)
        store.record(kept, at: Self.now.addingTimeInterval(-20 * 86400), counts: true)
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.dictionary = dictionary
        model.shelf = .starred
        await model.lookUp(" Serendipity ")
        #expect(dictionary.requests.isEmpty)
        #expect(model.lookupText == "Serendipity")
        #expect(model.selectedKey == kept.key && model.shelf == .all && model.freshKey == nil)
        #expect(store.entry(forKey: kept.key)?.lookupCount == 2)
        model.recordsHistory = false
        await model.lookUp("serendipity")
        #expect(store.entry(forKey: kept.key)?.lookupCount == 2, "history off keeps the count")
    }

    @Test func aNewWordGetsACardAndGoesIntoTheBook() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.dictionary = dictionary
        model.modelName = { "gpt-test" }
        model.lookupText = "serendipity"
        await model.lookUp()
        let entry = try #require(store.entry(forKey: key("serendipity")))
        #expect(entry.lookup.card == wordBookCard && entry.lookup.model == "gpt-test" && entry.lookupCount == 1)
        #expect(dictionary.requests.first?.generation == "0")
        #expect(model.displayed == entry && model.freshKey == entry.key && model.lookingUp == nil)
        #expect(model.counts[.today] == 2)
        await model.lookUp("")
        #expect(dictionary.requests.count == 1, "nothing to look up")
    }

    @Test func withHistoryOffOrForASentenceTheResultStaysLoose() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.dictionary = dictionary
        model.recordsHistory = false
        await model.lookUp("serendipity")
        let loose = try #require(model.transient)
        #expect(store.entry(forKey: loose.key) == nil)
        #expect(model.displayed == loose && model.isTransient(loose))
        model.toggleStar(loose)
        #expect(store.entry(forKey: loose.key)?.isStarred == true, "starring keeps it")
        #expect(model.transient == nil && model.selectedKey == loose.key)

        model.recordsHistory = true
        dictionary.answer = .translation("会议改到周五了。")
        await model.lookUp("The meeting moved to Friday.")
        let sentence = try #require(model.transient)
        #expect(sentence.lookup.translation == "会议改到周五了。" && sentence.lookup.card == nil)
        model.delete(sentence)
        #expect(model.transient == nil && model.deleted.isEmpty, "a loose result is just dismissed")
        model.selectedKey = key("beta")
        #expect(model.displayed?.headword == "beta")
    }

    @Test func lookingUpSaysWhatWentWrong() async throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.lookUp("serendipity")
        #expect(model.notice == L("ask.plugin.translate.noModel"))
        model.dictionary = AskFailingWordLookup()
        await model.lookUp("serendipity")
        #expect(model.notice == "offline" && model.lookingUp == nil && model.transient == nil)
    }

    @Test func thePreviewNeverLeavesTheMac() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.refreshPreview()
        #expect(model.preview == nil)
        model.lookupText = "hello"
        await model.refreshPreview()
        #expect(model.preview == nil, "no on-device pair, no preview")
        model.onDevice = AskTestTranslationEngine(available: true)
        await model.refreshPreview()
        #expect(model.preview == .device("[zh-Hans] hello"))
        store.record(AskWordBookLookup(headword: "hello", source: "en", target: "zh-Hans", card: wordBookCard),
                     at: Self.now, counts: true)
        await model.refreshPreview()
        #expect(model.preview == .kept("n. 机缘巧合；意外的好运  adj. 偶然的"))
    }

    @Test func theDirectionFollowsTheTextAndTabChangesIt() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.lookupText = "hello"
        #expect(model.direction(for: "hello").target == "zh-Hans")
        #expect(model.directionTitle == AskWordBookViewModel.pairTitle(pair, in: .simplifiedChinese))
        model.cycleTarget()
        let preset = try #require(model.targetPreset)
        #expect(preset != "zh-Hans" && preset != "en")
        #expect(model.direction(for: "hello").target == preset)
        model.detector = AskTestLanguageDetector(language: nil)
        model.lookupText = ""
        #expect(model.directionTitle.hasPrefix("→"))
    }

    // MARK: Changes

    @Test func starringAndDeletingWithUndo() throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.shelf = .starred
        let gamma = try #require(model.entries.last)
        model.toggleStar(gamma)
        #expect(model.entries.map(\.headword) == ["alpha"] && model.counts[.starred] == 1)
        #expect(model.notice == L("ask.wordBook.unstarred", "gamma"))
        model.shelf = .all
        let beta = try #require(model.entries.first { $0.headword == "beta" })
        model.selectedKey = beta.key
        model.delete(beta)
        #expect(store.entry(forKey: beta.key) == nil)
        #expect(model.notice == L("ask.wordBook.deleted", "beta"))
        #expect(model.selected?.headword == "gamma", "the next word is chosen")
        model.undoDelete()
        #expect(store.entry(forKey: beta.key) == beta)
        #expect(model.selectedKey == beta.key && model.deleted.isEmpty && model.notice == nil)
        model.undoDelete()
    }

    @Test func copyingReadingAloudAndAskingTheAI() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var copied: [String] = []
        var spoken: [(String, String)] = []
        var asked: [String] = []
        model.copy = { copied.append($0) }
        model.speakText = { spoken.append(($0, $1)) }
        model.askAI = { asked.append($0) }
        let alpha = try #require(model.selected)
        model.copyMeaning(alpha)
        #expect(model.notice == L("ask.wordBook.copied", "alpha 义"))
        model.speak(alpha)
        var chinese = alpha
        chinese.lookup = AskWordBookLookup(headword: "机缘", source: nil, target: "en", translation: "")
        model.speak(chinese)
        #expect(copied == ["alpha 义"])
        #expect(spoken.map(\.0) == ["alpha", "机缘"] && spoken.map(\.1) == ["en", "zh-Hans"])
        model.ask(about: alpha)
        var carded = alpha
        carded.lookup.card = wordBookCard
        model.ask(about: carded)
        #expect(asked.count == 2 && asked[0].contains("alpha") && asked[1].contains(wordBookCard.markdown))
    }

    @Test func regeneratingKeepsTheNewCardWithoutCounting() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let alpha = try #require(model.selected)
        #expect(!model.canRegenerate)
        await model.regenerate(alpha)
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.dictionary = dictionary
        model.modelName = { "gpt-test" }
        await model.regenerate(alpha)
        let entry = try #require(store.entry(forKey: alpha.key))
        #expect(entry.lookup.card == wordBookCard && entry.lookup.model == "gpt-test" && entry.lookupCount == 1)
        #expect(dictionary.requests.first?.generation != "0")
        #expect(model.notice == L("ask.wordBook.regenerated", "alpha") && model.regenerating == nil)
        dictionary.answer = .translation("text")
        await model.regenerate(alpha)
        #expect(model.notice == L("ask.wordBook.regenerate.failed"))
        model.dictionary = AskFailingWordLookup()
        await model.regenerate(alpha)
        #expect(model.notice == "offline")
        // A loose result gets its new card without entering the book.
        model.dictionary = dictionary
        dictionary.answer = .card(wordBookCard)
        model.recordsHistory = false
        await model.lookUp("loose")
        let loose = try #require(model.transient)
        await model.regenerate(loose)
        #expect(model.transient?.lookup.card == wordBookCard && store.entry(forKey: loose.key) == nil)
    }

    @Test func exportWritesWhatTheListShows() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.shelf = .starred
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var asked: [String] = []
        model.chooseExportURL = { name in asked.append(name); return folder.appendingPathComponent(name) }
        model.export(.csv)
        let url = folder.appendingPathComponent(L("ask.wordBook.title") + ".csv")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 3, "header and the two starred words")
        #expect(model.notice == L("ask.wordBook.exported", 2))
        model.chooseExportURL = { name in asked.append(name); return nil }
        model.notice = nil
        model.export(.anki)
        #expect(model.notice == nil, "cancelled")
        model.filterText = "zzz"
        model.export(.csv)
        #expect(asked.count == 2, "nothing to export asks nothing")
        model.filterText = ""
        model.chooseExportURL = { _ in URL(fileURLWithPath: "/dev/null/nope.csv") }
        model.export(.markdown)
        #expect(model.notice != nil && model.notice != L("ask.wordBook.exported", 2))
    }

    @Test func settingsPurgeAndClear() throws {
        let (model, store, settings, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.recordsHistory = false
        #expect(!settings.askWordBookRecordsHistory)
        model.retention = .week
        #expect(settings.askWordBookRetention == .week)
        #expect(store.count(.all) == 3, "delta and epsilon were older than a week")
        model.retention = .forever
        #expect(store.count(.all) == 3)
        model.clearHistory()
        #expect(store.count(.all) == 2 && model.counts[.all] == 2)
    }

    @Test func pagesLoadAsTheListScrolls() throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.loadMore()
        #expect(model.entries.count == 5)
        for index in 0 ..< AskWordBookViewModel.pageSize {
            store.record(AskWordBookLookup(headword: "w\(index)", source: "en", target: "ja", translation: "x"),
                         at: Self.now, counts: true)
        }
        model.reload()
        #expect(model.entries.count == AskWordBookViewModel.pageSize)
        model.loadMore()
        #expect(model.entries.count == AskWordBookViewModel.pageSize + 5)
    }

    @Test func changesElsewhereShowUp() async throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.notificationCenter = .default
        store.setStarred(true, lookup: AskWordBookLookup(headword: "beta", source: "en", target: "zh-Hans"), at: Self.now)
        for _ in 0 ..< 1000 where model.counts[.starred] != 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.counts[.starred] == 3)
    }

    @Test func pairsAreNamedInTheInterfaceLanguage() {
        #expect(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: "en", target: "ja"), in: .english)
            == "English → Japanese")
        #expect(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: nil, target: "ja"), in: .english)
            == "→ Japanese")
    }

    @Test func theViewDrawsEveryState() async throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        func draw() {
            let hosting = NSHostingView(rootView: AskWordBookView(model: model) {})
            hosting.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
            hosting.layoutSubtreeIfNeeded()
            _ = hosting.fittingSize
        }
        draw()
        model.shelf = .starred
        model.recordsHistory = false
        draw()
        model.filterText = "zzz"
        draw()
        model.filterText = ""
        model.dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.askAI = { _ in }
        model.notice = "note"
        draw()
        await model.lookUp("serendipity")
        draw()
        model.clearHistory()
        model.shelf = .all
        for entry in model.entries { model.delete(entry) }
        draw()
    }

    @Test func rowsAndChipsDraw() {
        let entry = AskWordBookEntry(id: UUID(), lookup: AskWordBookLookup(headword: "w", source: "en", target: "zh-Hans",
                                                                          card: wordBookCard),
                                     lookupCount: 3, firstLookedUpAt: Self.now, lastLookedUpAt: Self.now, starredAt: Self.now)
        for view in [AnyView(AskWordBookRow(entry: entry, selected: true, select: {}, star: {})),
                     AnyView(AskWordBookFlow { Text("a"); Text("b"); Text("c") }.frame(width: 20)),
                     AnyView(Button("x") {}.buttonStyle(AskWordBookPressStyle())),
                     AnyView(Button("y") {}.buttonStyle(AskWordBookChipStyle()))] {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height > 0)
        }
        let rows = AskWordBookFlow(spacing: 4)
        #expect(rows.spacing == 4)
    }
}

@Suite("Ask word book window", .serialized)
@MainActor
struct AskWordBookWindowTests {
    @Test func opensOnceShowsTheWordAskedForAndLooksWordsUp() async throws {
        let store = makeTestWordBook()
        let lookup = AskWordBookLookup(headword: "beta", source: "en", target: "zh-Hans", translation: "b")
        store.record(lookup, at: Date(), counts: true)
        store.record(AskWordBookLookup(headword: "alpha", source: "en", target: "zh-Hans", translation: "a"),
                     at: Date(), counts: true)
        let controller = AskWordBookWindowController()
        controller.show()
        controller.show(lookingUp: "nothing")
        #expect(controller.window == nil, "nothing to show before the launcher configures it")
        let suite = "wordbook-window-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        controller.configure(store: store, dictionary: nil, settings: settings, modelName: { "m" })
        controller.show(selecting: lookup.key)
        let window = try #require(controller.window)
        #expect(window.title == L("ask.wordBook.title"))
        #expect(window.styleMask.contains(.fullSizeContentView) && window.titleVisibility == .hidden)
        #expect(controller.model?.selectedKey == lookup.key)
        controller.show()
        #expect(controller.window === window, "one window")
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        var asked: [String] = []
        controller.configure(store: store, dictionary: dictionary, settings: settings, askAI: { asked.append($0) },
                             modelName: { "m" })
        #expect(controller.model?.canRegenerate == true && controller.model?.askAI != nil)
        controller.show(lookingUp: "serendipity")
        #expect(controller.model?.lookupText == "serendipity")
        for _ in 0 ..< 400 where dictionary.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(dictionary.requests.first?.text == "serendipity")
        window.close()
        #expect(controller.window == nil && controller.model == nil)
    }
}
