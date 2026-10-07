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

@Suite("Ask word book dialog", .serialized)
@MainActor
struct AskWordBookViewModelTests {
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
        model.now = { Self.now }
        model.reload()
        return (model, store, settings, suite)
    }

    private func key(_ word: String) -> String { AskWordBookEntry.key(headword: word, source: "en", target: "zh-Hans") }

    @Test func opensOnTheStarredWordsAndCounts() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(model.scope == .starred)
        #expect(model.entries.map(\.headword) == ["alpha", "gamma"])
        #expect(model.selectedKey == key("alpha"))
        #expect(model.starredCount == 2 && model.totalCount == 5 && model.recentCount == 3)
        #expect(model.sections.count == 1 && model.sections[0].period == nil)
        #expect(model.pairs == [AskWordBookLanguagePair(source: "en", target: "zh-Hans")])
    }

    @Test func historyIsGroupedByDayWhenInDateOrder() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.scope = .all
        #expect(model.sections.map(\.period) == [.today, .yesterday, .week, .month, .earlier])
        model.sort = .alphabetical
        #expect(model.sections.map(\.period) == [nil])
        #expect(model.entries.map(\.headword) == ["alpha", "beta", "delta", "epsilon", "gamma"])
        model.searchText = "zzz"
        #expect(model.sections.isEmpty && model.selected == nil)
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
        model.searchText = "alp"
        model.reveal(key("delta"))
        #expect(model.scope == .all && model.searchText.isEmpty && model.selectedKey == key("delta"))
        model.reveal(key("gamma"))
        #expect(model.scope == .starred && model.selected?.headword == "gamma")
        model.reveal("unknown")
        model.reveal(nil)
        #expect(model.selectedKey == key("gamma"))
    }

    @Test func arrowsMoveThroughTheList() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.scope = .all
        model.moveSelection(1)
        #expect(model.selected?.headword == "beta")
        model.moveSelection(10)
        #expect(model.selected?.headword == "epsilon")
        model.moveSelection(-1)
        #expect(model.selected?.headword == "delta")
        model.selectedKey = nil
        model.moveSelection(1)
        #expect(model.selected?.headword == "alpha")
        model.searchText = "zzz"
        model.moveSelection(1)
        #expect(model.selected == nil)
    }

    @Test func starringAndDeletingWithUndo() throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let gamma = try #require(model.entries.last)
        model.toggleStar(gamma)
        #expect(model.entries.map(\.headword) == ["alpha"] && model.starredCount == 1)
        model.scope = .all
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

    @Test func copyingAndReadingAloud() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var copied: [String] = []
        var spoken: [(String, String)] = []
        model.copy = { copied.append($0) }
        model.speakText = { spoken.append(($0, $1)) }
        let alpha = try #require(model.selected)
        model.copyMeaning(alpha)
        model.speak(alpha)
        var chinese = alpha
        chinese.lookup = AskWordBookLookup(headword: "机缘", source: nil, target: "en", translation: "")
        model.speak(chinese)
        #expect(copied == ["alpha 义"])
        #expect(model.notice == L("ask.plugin.copied"))
        #expect(spoken.map(\.0) == ["alpha", "机缘"] && spoken.map(\.1) == ["en", "zh-Hans"])
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
        #expect(model.canRegenerate)
        await model.regenerate(alpha)
        let entry = try #require(store.entry(forKey: alpha.key))
        #expect(entry.lookup.card == wordBookCard && entry.lookup.model == "gpt-test" && entry.lookupCount == 1)
        #expect(dictionary.requests.first?.text == "alpha" && dictionary.requests.first?.generation != "0")
        #expect(model.notice == L("ask.wordBook.regenerated", "alpha") && model.regenerating == nil)
        dictionary.answer = .translation("text")
        await model.regenerate(alpha)
        #expect(model.notice == L("ask.wordBook.regenerate.failed"))
    }

    @Test func exportWritesWhatTheListShows() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
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
        model.searchText = "zzz"
        model.export(.csv)
        #expect(asked.count == 2, "nothing to export asks nothing")
        model.searchText = ""
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
        #expect(store.count(.all) == 2 && model.totalCount == 2)
    }

    @Test func pagesLoadAsTheListScrolls() throws {
        let (model, store, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.scope = .all
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
        for _ in 0 ..< 1000 where model.starredCount != 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.starredCount == 3)
    }

    @Test func pairsAreNamedInTheInterfaceLanguage() {
        #expect(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: "en", target: "ja"), in: .english)
            == "English → Japanese")
        #expect(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: nil, target: "ja"), in: .english)
            == "→ Japanese")
    }

    @Test func theViewDrawsEveryState() throws {
        let (model, _, _, suite) = try fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        func draw() {
            let hosting = NSHostingView(rootView: AskWordBookView(model: model) {})
            hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
            hosting.layoutSubtreeIfNeeded()
            _ = hosting.fittingSize
        }
        draw()
        model.scope = .all
        model.recordsHistory = false
        draw()
        model.searchText = "zzz"
        draw()
        model.searchText = ""
        model.dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.notice = "note"
        draw()
    }
}

@Suite("Ask word book window", .serialized)
@MainActor
struct AskWordBookWindowTests {
    @Test func opensOnceAndShowsTheWordAskedFor() throws {
        let store = makeTestWordBook()
        let lookup = AskWordBookLookup(headword: "beta", source: "en", target: "zh-Hans", translation: "b")
        store.record(lookup, at: Date(), counts: true)
        store.record(AskWordBookLookup(headword: "alpha", source: "en", target: "zh-Hans", translation: "a"),
                     at: Date(), counts: true)
        let controller = AskWordBookWindowController()
        controller.show()
        #expect(controller.window == nil, "nothing to show before the launcher configures it")
        let suite = "wordbook-window-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.configure(store: store, dictionary: nil, settings: SettingsStore(defaults: try #require(UserDefaults(suiteName: suite))),
                             modelName: { "m" })
        controller.show(selecting: lookup.key)
        let window = try #require(controller.window)
        #expect(window.title == L("ask.wordBook.title"))
        #expect(controller.model?.selectedKey == lookup.key && controller.model?.scope == .all)
        controller.show()
        #expect(controller.window === window, "one window")
        controller.configure(store: store, dictionary: AskTestWordLookup(answer: .card(wordBookCard)),
                             settings: SettingsStore(defaults: try #require(UserDefaults(suiteName: suite))), modelName: { "m" })
        #expect(controller.model?.canRegenerate == true)
        window.close()
        #expect(controller.window == nil && controller.model == nil)
    }
}
