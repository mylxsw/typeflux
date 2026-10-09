import Foundation
import Testing
@testable import Typeflux

/// A word book in a fresh database file of its own.
func makeTestWordBook() -> SQLiteAskWordBookStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wordbook-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("word-book.sqlite")
    let store = SQLiteAskWordBookStore(url: url)
    store.notificationCenter = NotificationCenter()
    return store
}

let wordBookCard = AskWordCard(
    headword: "serendipity",
    phonetics: [.init(label: "UK", text: "/ˌserənˈdɪpəti/")],
    senses: [.init(pos: "n.", meanings: ["机缘巧合", "意外的好运"]), .init(pos: "adj.", meanings: ["偶然的"])],
    examples: [.init(source: "Pure **serendipity**.", target: "纯属巧合。")],
    synonyms: ["chance"]
)

private func day(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + offset * 86400) }

@Suite("Ask word book entries")
struct AskWordBookEntryTests {
    @Test func keysFoldSpacingCaseAndLanguageVariants() {
        let key = AskWordBookEntry.key(headword: "  Take   Off ", source: "en-US", target: "zh-Hans")
        #expect(key == "take off|en|zh-hans")
        #expect(key == AskWordBookEntry.key(headword: "take off", source: "en", target: "zh"))
        #expect(AskWordBookEntry.key(headword: "x", source: nil, target: "zh-Hant") == "x||zh-hant")
        #expect(AskWordBookEntry.key(headword: "x", source: "en", target: "zh-Hans")
            != AskWordBookEntry.key(headword: "x", source: "en", target: "ja"))
    }

    @Test func summaryAndFirstMeaningComeFromTheCardOrTheTranslation() {
        let card = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard)
        #expect(card.summary == "n. 机缘巧合；意外的好运  adj. 偶然的")
        #expect(card.firstMeaning == "机缘巧合")
        let text = AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans", translation: "有弹性的；适应力强的")
        #expect(text.summary == "有弹性的；适应力强的")
        #expect(text.firstMeaning == "有弹性的")
        let empty = AskWordBookLookup(headword: "x", source: nil, target: "en", translation: " ")
        #expect(empty.firstMeaning == nil)
        #expect(AskWordBookLookup(headword: "x", source: nil, target: "en").summary.isEmpty)
        let posless = AskWordCard(headword: "x", senses: [.init(pos: "", meanings: ["a"])])
        #expect(AskWordBookLookup(headword: "x", source: nil, target: "en", card: posless).summary == "a")
    }

    @Test func retentionCutoffs() {
        let now = day(100)
        #expect(AskWordBookRetention.default == .quarter)
        #expect(AskWordBookRetention.week.cutoff(now: now) == day(93))
        #expect(AskWordBookRetention.month.cutoff(now: now) == day(70))
        #expect(AskWordBookRetention.quarter.cutoff(now: now) == day(10))
        #expect(AskWordBookRetention.forever.cutoff(now: now) == nil)
    }

    @Test func settingsDefaultToRecordingForNinetyDays() throws {
        let suite = "wordbook-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askWordBookRecordsHistory)
        #expect(settings.askWordBookRetention == .quarter)
        settings.askWordBookRecordsHistory = false
        settings.askWordBookRetention = .forever
        #expect(!settings.askWordBookRecordsHistory)
        #expect(settings.askWordBookRetention == .forever)
        defaults.set("bogus", forKey: "ask.wordBook.retention")
        #expect(settings.askWordBookRetention == .quarter)
    }
}

@Suite("Ask word book store")
struct AskWordBookStoreTests {
    private let english = AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans",
                                            translation: "有弹性的", model: nil)
    private let cardLookup = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans",
                                               card: wordBookCard, model: "gpt-test")

    @Test func recordingAddsThenCounts() throws {
        let store = makeTestWordBook()
        let first = try #require(store.record(english, at: day(0), counts: true))
        #expect(first.lookupCount == 1 && first.firstLookedUpAt == day(0) && !first.isStarred)
        store.record(english, at: day(2), counts: true)
        let again = try #require(store.record(english, at: day(3), counts: false))
        #expect(again.lookupCount == 2, "an update without counting keeps the count")
        #expect(again.lastLookedUpAt == day(2) && again.firstLookedUpAt == day(0))
        #expect(again.id == first.id)
        #expect(store.entry(forKey: english.key) == again)
        #expect(store.entry(forKey: "missing") == nil)
    }

    @Test func aCardIsKeptWholeAndNeverReplacedByATranslation() throws {
        let store = makeTestWordBook()
        store.record(cardLookup, at: day(0), counts: true)
        #expect(store.entry(forKey: cardLookup.key)?.lookup.card == wordBookCard)
        var plain = cardLookup
        plain.card = nil
        plain.translation = "机缘"
        plain.model = nil
        let kept = try #require(store.record(plain, at: day(1), counts: true))
        #expect(kept.lookup.card == wordBookCard && kept.lookup.translation == nil)
        #expect(kept.lookup.model == "gpt-test", "a lookup without a model keeps the one that wrote the card")
        var newer = cardLookup
        newer.card = AskWordCard(headword: "serendipity", senses: [.init(pos: "n.", meanings: ["新释义"])])
        newer.model = "other"
        let replaced = try #require(store.record(newer, at: day(2), counts: false))
        #expect(replaced.lookup.card == newer.card && replaced.lookup.model == "other")
    }

    @Test func aTranslationUpgradesToACardAndTheHeadwordStaysAsTyped() throws {
        let store = makeTestWordBook()
        let typed = AskWordBookLookup(headword: "Serendipity", source: nil, target: "zh-Hans", translation: "机缘")
        store.record(typed, at: day(0), counts: true)
        var upgrade = typed
        upgrade.card = AskWordCard(headword: "serendipity", senses: [.init(pos: "n.", meanings: ["机缘巧合"])])
        let entry = try #require(store.record(upgrade, at: day(1), counts: true))
        #expect(entry.lookup.headword == "Serendipity")
        #expect(entry.lookup.card != nil && entry.lookup.translation == "机缘")
        #expect(entry.lookupCount == 2)
    }

    @Test func starringAddsUnknownWordsAndKeepsTheFirstStarDate() throws {
        let store = makeTestWordBook()
        #expect(store.setStarred(false, lookup: english, at: day(0)) == nil, "unstarring an unknown word adds nothing")
        #expect(store.count(.all) == 0)
        let starred = try #require(store.setStarred(true, lookup: english, at: day(1)))
        #expect(starred.isStarred && starred.starredAt == day(1) && starred.lookupCount == 1)
        #expect(store.setStarred(true, lookup: english, at: day(5))?.starredAt == day(1))
        #expect(store.setStarred(false, lookup: english, at: day(6))?.isStarred == false)
        #expect(store.count(.starred) == 0 && store.count(.all) == 1)
    }

    @Test func listingFiltersSearchesSortsAndPages() {
        let store = makeTestWordBook()
        let words: [(String, String?, String, Double, Int)] = [
            ("apple", "en", "zh-Hans", 3, 1), ("Banana", "en", "zh-Hans", 1, 3), ("cherry", "en", "ja", 2, 2),
            ("机缘", "zh-Hans", "en", 4, 1), ("100%_sure", nil, "zh-Hans", 0, 1)
        ]
        for (word, source, target, when, times) in words {
            let lookup = AskWordBookLookup(headword: word, source: source, target: target, translation: word + " 释义")
            for index in 0 ..< times { store.record(lookup, at: day(when + Double(index) / 10), counts: true) }
        }
        store.setStarred(true, lookup: AskWordBookLookup(headword: "cherry", source: "en", target: "ja"), at: day(9))
        store.setStarred(true, lookup: AskWordBookLookup(headword: "apple", source: "en", target: "zh-Hans"), at: day(8))
        func heads(_ query: AskWordBookQuery) -> [String] { store.list(query).map(\.headword) }
        #expect(heads(AskWordBookQuery()) == ["机缘", "apple", "cherry", "Banana", "100%_sure"])
        #expect(heads(AskWordBookQuery(sort: .count)) == ["Banana", "cherry", "机缘", "apple", "100%_sure"])
        #expect(heads(AskWordBookQuery(sort: .alphabetical)) == ["100%_sure", "apple", "Banana", "cherry", "机缘"])
        #expect(heads(AskWordBookQuery(sort: .starred)).prefix(2) == ["cherry", "apple"])
        #expect(heads(AskWordBookQuery(scope: .starred)) == ["apple", "cherry"])
        #expect(heads(AskWordBookQuery(text: "an")) == ["Banana"])
        #expect(heads(AskWordBookQuery(text: "释义")).count == 5, "meanings match too")
        #expect(heads(AskWordBookQuery(text: "%_")) == ["100%_sure"], "LIKE wildcards are literal")
        #expect(heads(AskWordBookQuery(text: "  ")).count == 5)
        #expect(heads(AskWordBookQuery(pair: AskWordBookLanguagePair(source: "en", target: "ja"))) == ["cherry"])
        #expect(heads(AskWordBookQuery(pair: AskWordBookLanguagePair(source: nil, target: "zh-Hans"))) == ["100%_sure"])
        #expect(heads(AskWordBookQuery(limit: 2, offset: 1)) == ["apple", "cherry"])
        #expect(store.languagePairs().first == AskWordBookLanguagePair(source: "en", target: "zh-Hans"))
        #expect(store.languagePairs().count == 4)
        #expect(store.lookups(since: day(2)) == 3)
    }

    @Test func deletingRestoringAndPurging() throws {
        let store = makeTestWordBook()
        let old = AskWordBookLookup(headword: "old", source: "en", target: "zh-Hans", translation: "旧")
        let fresh = AskWordBookLookup(headword: "fresh", source: "en", target: "zh-Hans", translation: "新")
        store.record(old, at: day(0), counts: true)
        store.record(fresh, at: day(10), counts: true)
        store.setStarred(true, lookup: cardLookup, at: day(0))
        let removed = try #require(store.entry(forKey: old.key))
        store.delete(keys: [old.key])
        store.delete(keys: [])
        #expect(store.entry(forKey: old.key) == nil)
        store.restore([removed])
        store.restore([])
        #expect(store.entry(forKey: old.key) == removed)
        store.purgeHistory(before: day(5))
        #expect(store.entry(forKey: old.key) == nil)
        #expect(store.entry(forKey: fresh.key) != nil)
        #expect(store.entry(forKey: cardLookup.key) != nil, "starred words stay however old")
        store.purgeHistory(before: nil)
        #expect(store.list(AskWordBookQuery()).map(\.headword) == ["serendipity"])
    }

    @Test func changesAreAnnounced() async throws {
        let store = makeTestWordBook()
        let center = NotificationCenter()
        store.notificationCenter = center
        let counter = Counter()
        let token = center.addObserver(forName: .askWordBookDidChange, object: nil, queue: .main) { _ in counter.add() }
        defer { center.removeObserver(token) }
        store.record(english, at: day(0), counts: true)
        for _ in 0 ..< 1000 where counter.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(counter.value == 1)
    }

    @Test func aStoreThatCannotOpenAnswersEmpty() {
        let store = SQLiteAskWordBookStore(url: URL(fileURLWithPath: "/dev/null/nowhere/word-book.sqlite"))
        store.notificationCenter = NotificationCenter()
        #expect(store.entry(forKey: "x") == nil)
        #expect(store.record(english, at: day(0), counts: true) == nil)
        #expect(store.list(AskWordBookQuery()).isEmpty)
        #expect(store.count(.all) == 0 && store.lookups(since: day(0)) == 0 && store.languagePairs().isEmpty)
    }

    @Test func datesLimitListsAndCountsFollowQueries() {
        let store = makeTestWordBook()
        for (word, when) in [("old", 0.0), ("mid", 5.0), ("new", 9.0)] {
            store.record(AskWordBookLookup(headword: word, source: "en", target: "zh-Hans", translation: word),
                         at: day(when), counts: true)
        }
        store.record(AskWordBookLookup(headword: "mid", source: "en", target: "zh-Hans", translation: "mid"),
                     at: day(8), counts: true)
        #expect(store.list(AskWordBookQuery(since: day(6))).map(\.headword) == ["new", "mid"])
        #expect(store.count(matching: AskWordBookQuery(since: day(6))) == 2)
        #expect(store.count(matching: AskWordBookQuery(text: "ol")) == 1)
        #expect(store.count(matching: AskWordBookQuery(scope: .starred)) == 0)
        #expect(store.activity(since: day(6)).count == 3, "first and last lookups of recent words, from the date on")
        #expect(Set(store.activity(since: day(6))) == [day(8), day(9)])
        #expect(Set(store.activity(since: day(0))) == [day(0), day(5), day(8), day(9)])
    }

    @Test func likePatternsAreEscaped() {
        #expect(SQLiteAskWordBookStore.escapeLike(#"a%b_c\d"#) == #"a\%b\_c\\d"#)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func add() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }
}

@Suite("Ask word book recorder", .exclusiveUIState)
@MainActor
struct AskWordBookRecorderTests {
    private let lookup = AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans", translation: "有弹性的")

    @Test func countsEachWordOncePerSessionAndHonoursTheSwitch() {
        let store = makeTestWordBook()
        var enabled = true
        let recorder = AskWordBookRecorder(store: store) { enabled }
        recorder.now = { day(0) }
        recorder.record(lookup)
        recorder.record(lookup)
        #expect(store.entry(forKey: lookup.key)?.lookupCount == 1)
        recorder.beginSession()
        recorder.record(lookup)
        #expect(store.entry(forKey: lookup.key)?.lookupCount == 2)
        enabled = false
        recorder.beginSession()
        recorder.record(lookup)
        #expect(store.entry(forKey: lookup.key)?.lookupCount == 2)
        recorder.record(AskWordBookLookup(headword: "", source: nil, target: "en"))
        #expect(store.count(.all) == 1)
    }

    @Test func starringTogglesAndWorksWithRecordingOff() {
        let store = makeTestWordBook()
        let recorder = AskWordBookRecorder(store: store) { false }
        #expect(!recorder.isStarred(lookup.key))
        #expect(recorder.toggleStar(lookup))
        #expect(recorder.isStarred(lookup.key))
        #expect(!recorder.toggleStar(lookup))
        #expect(store.count(.all) == 1)
    }
}

@Suite("Ask translate plugin and the word book")
struct AskTranslateWordBookTests {
    private func plugin(_ store: SQLiteAskWordBookStore?, local: Bool = true,
                        dictionary: AskTestWordLookup? = nil) -> AskTranslatePlugin {
        AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: local), ai: AskTestTranslationEngine(),
                           dictionary: dictionary, wordBook: store, aiName: { "gpt-test" },
                           detector: AskTestLanguageDetector(language: "en"))
    }

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument,
                         options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskTranslatePlugin.keywords[0], options: options,
                         interfaceLanguage: .simplifiedChinese)
    }

    @Test func aWordTranslatedOnThisMacSettlesLaterAndCanBeStarred() async throws {
        let store = makeTestWordBook()
        let translate = plugin(store)
        let plan = await translate.plan(request(" resilient "))
        let output = try await translate.run(request(" resilient "), plan: plan)
        let lookup = try #require(output.wordBook)
        #expect(lookup == AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans",
                                            translation: "[zh-Hans]  resilient ", model: nil))
        #expect(!output.recordsAtOnce)
        #expect(output.starred == false)
        let star = try #require(output.action(for: .commandS))
        #expect(star.kind == .toggleStar(lookup) && star.title == L("ask.wordBook.star") && star.symbol == "star")
        #expect(output.detail == nil, "nothing to say the first time")
    }

    @Test func sentencesAndPluginsWithoutAWordBookKeepNothing() async throws {
        let sentence = request("The meeting has moved to Friday.")
        let store = makeTestWordBook()
        let withBook = plugin(store)
        let output = try await withBook.run(sentence, plan: await withBook.plan(sentence))
        #expect(output.wordBook == nil && output.starred == nil && output.action(for: .commandS) == nil)
        let without = plugin(nil)
        let word = request("hello")
        let plain = try await without.run(word, plan: await without.plan(word))
        #expect(plain.wordBook == nil && plain.action(for: .commandS) == nil)
    }

    @Test func anAICardIsKeptAtOnceAndShowsHowOftenItWasSeen() async throws {
        let store = makeTestWordBook()
        let earlier = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", translation: "机缘")
        store.record(earlier, at: day(0), counts: true)
        store.setStarred(true, lookup: earlier, at: day(0))
        let dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        let translate = plugin(store, local: false, dictionary: dictionary)
        let word = request("serendipity")
        let plan = await translate.plan(word)
        #expect(plan.values["engine"] == "ai")
        let output = try await translate.run(word, plan: plan)
        #expect(output.wordCard == wordBookCard)
        #expect(output.wordBook?.card == wordBookCard && output.wordBook?.model == "gpt-test")
        #expect(output.recordsAtOnce)
        #expect(output.starred == true)
        #expect(output.action(for: .commandS)?.title == L("ask.wordBook.unstar"))
        #expect(output.detail == L("ask.wordBook.seen", 1))
        #expect(!output.meta.contains { $0.text == L("ask.wordBook.seen", 1) }, "the language chips stay a path")
    }

    @Test func anAITranslationOfAWordWithoutADictionaryIsKeptAtOnce() async throws {
        let store = makeTestWordBook()
        let translate = plugin(store, local: false)
        let word = request("hello")
        let output = try await translate.run(word, plan: await translate.plan(word))
        #expect(output.wordBook?.translation == "[zh-Hans] hello" && output.wordBook?.model == "gpt-test")
        #expect(output.recordsAtOnce)
    }

    @Test func aKeptCardShowsAgainWithoutAskingTheAI() async throws {
        let store = makeTestWordBook()
        let saved = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard,
                                      model: "gpt-test")
        store.record(saved, at: day(0), counts: true)
        let dictionary = AskTestWordLookup(answer: .translation("unused"))
        let translate = plugin(store, local: true, dictionary: dictionary)
        let word = request("Serendipity")
        let plan = await translate.plan(word)
        #expect(plan.mode == .live && plan.values["engine"] == "book")
        #expect(plan.title == L("ask.plugin.translate.wordCard"))
        let output = try await translate.run(word, plan: plan)
        #expect(dictionary.requests.isEmpty)
        #expect(output.wordCard == wordBookCard)
        #expect(output.source == L("ask.plugin.source.wordBook") && !output.sourceIsAI)
        #expect(!output.recordsAtOnce, "shown while typing, it waits to settle")
        #expect(output.wordBook?.model == nil)
        // The selection still waits for Return, card or not, and then counts at once.
        let selected = request("serendipity", origin: .selection)
        let selectedPlan = await translate.plan(selected)
        #expect(selectedPlan.mode == .onSubmit)
        #expect(try await translate.run(selected, plan: selectedPlan).recordsAtOnce)
        // ⌘R asks the AI for a new card.
        let again = request("serendipity", options: ["engine": "ai", "generation": "1"])
        #expect(await translate.plan(again).values["engine"] == "ai")
        _ = try await translate.run(again, plan: await translate.plan(again))
        #expect(dictionary.requests.count == 1)
    }

    @Test func aGarbledOrSentenceReplyIsNotKept() async throws {
        let store = makeTestWordBook()
        for answer in [AskWordLookup.translation("一句话"), .unreadable("hm")] {
            let translate = plugin(store, local: false, dictionary: AskTestWordLookup(answer: answer))
            let word = request("serendipity")
            let output = try await translate.run(word, plan: await translate.plan(word))
            #expect(output.wordBook == nil && output.action(for: .commandS) == nil)
        }
    }

    @Test func starringSwapsTheActionInPlace() async throws {
        let store = makeTestWordBook()
        let translate = plugin(store)
        let word = request("resilient")
        let output = try await translate.run(word, plan: await translate.plan(word))
        let starred = output.starring(true)
        #expect(starred.starred == true)
        #expect(starred.action(for: .commandS)?.title == L("ask.wordBook.unstar"))
        #expect(starred.action(for: .commandS)?.symbol == "star.fill")
        #expect(starred.actions.count == output.actions.count)
        #expect(starred.starring(false).action(for: .commandS)?.title == L("ask.wordBook.star"))
        let sentence = request("A whole sentence here.")
        let plain = try await translate.run(sentence, plan: await translate.plan(sentence))
        #expect(plain.starring(true) == plain)
    }
}

/// A plugin that returns one fixed result with a word book lookup.
private final class AskWordBookTestPlugin: AskLauncherPlugin, @unchecked Sendable {
    var atOnce = false
    let id = "wb"
    let title = "WB"
    let symbol = "book"
    var defaultKeywords: [AskKeyword] { [AskKeyword(keyword: "wb", pluginID: id)] }
    static let lookup = AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans", translation: "有弹性的")

    func placeholder(selectionLines: Int?) -> String { "" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan { AskPluginPlan(mode: .live, title: "t") }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        var output = AskPluginOutput(body: request.text, original: request.text, meta: [], source: "s",
                                     actions: [AskTranslatePlugin.starAction(Self.lookup, starred: false)])
        output.wordBook = Self.lookup
        output.recordsAtOnce = atOnce
        output.starred = false
        return output
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}

@Suite("Ask plugin session and the word book", .serialized, .exclusiveUIState)
@MainActor
struct AskPluginSessionWordBookTests {
    private func makeSession(_ plugin: AskWordBookTestPlugin) -> (AskPluginSession, Recorded) {
        let recorded = Recorded()
        let session = AskPluginSession(plugins: [plugin]) { plugin.defaultKeywords }
        session.debounce = .milliseconds(1)
        session.recordWordBook = { recorded.lookups.append($0) }
        session.beginWordBookSession = { recorded.sessions += 1 }
        return (session, recorded)
    }

    @MainActor final class Recorded {
        var lookups: [AskWordBookLookup] = []
        var sessions = 0
    }

    private func start(_ session: AskPluginSession, _ text: String) async throws {
        _ = session.detect(in: "wb " + text)
        session.update(text: text, selection: nil, language: .english)
        for _ in 0 ..< 400 where session.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.output != nil)
    }

    @Test func aLiveResultCountsOnlyOnceUsedOrShownLongEnough() async throws {
        let (session, recorded) = makeSession(AskWordBookTestPlugin())
        var now = day(0)
        session.clock = { now }
        try await start(session, "resilient")
        #expect(recorded.sessions == 1)
        #expect(recorded.lookups.isEmpty, "a live result waits to settle")
        now = day(0).addingTimeInterval(1)
        session.deactivate()
        #expect(recorded.lookups.isEmpty, "closed too soon to count")

        try await start(session, "resilient")
        now = now.addingTimeInterval(2)
        session.deactivate()
        #expect(recorded.lookups == [AskWordBookTestPlugin.lookup])

        try await start(session, "resilient")
        session.settleWordBook()
        #expect(recorded.lookups.count == 2)
    }

    @Test func aReturnResultCountsAtOnce() async throws {
        let plugin = AskWordBookTestPlugin()
        plugin.atOnce = true
        let (session, recorded) = makeSession(plugin)
        try await start(session, "resilient")
        #expect(recorded.lookups == [AskWordBookTestPlugin.lookup])
    }

    @Test func starsShowWithoutRunningAgain() async throws {
        let (session, _) = makeSession(AskWordBookTestPlugin())
        try await start(session, "resilient")
        session.showStarred(true, key: "other|en|zh-hans")
        #expect(session.output?.starred == false)
        session.showStarred(true, key: AskWordBookTestPlugin.lookup.key)
        #expect(session.output?.starred == true)
        #expect(session.output?.action(for: .commandS)?.title == L("ask.wordBook.unstar"))
    }
}
