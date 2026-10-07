import AppKit
import Foundation

// swiftlint:disable file_length

/// What the word book window shows and does: a shelf of words (all, starred, today,
/// this week, a language direction), filtered and sorted; the chosen word; looking a
/// word up in the window; and the changes made to them
/// (`docs/design/word-book-redesign.md`).
@MainActor
final class AskWordBookViewModel: ObservableObject {
    /// A day heading in the list.
    enum Period: Int, CaseIterable, Sendable {
        case today, yesterday, week, month, earlier

        var title: String {
            switch self {
            case .today: L("ask.wordBook.period.today")
            case .yesterday: L("ask.wordBook.period.yesterday")
            case .week: L("ask.wordBook.period.week")
            case .month: L("ask.wordBook.period.month")
            case .earlier: L("ask.wordBook.period.earlier")
            }
        }

        static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> Period {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            switch days {
            case ..<1: return .today
            case 1: return .yesterday
            case 2 ..< 7: return .week
            case 7 ..< 31: return .month
            default: return .earlier
            }
        }
    }

    /// What the sidebar offers.
    enum Shelf: Hashable, Sendable {
        case all, starred, today, week
        case pair(AskWordBookLanguagePair)
    }

    struct Section: Identifiable, Equatable {
        var period: Period?
        var entries: [AskWordBookEntry]
        var id: Int { period?.rawValue ?? -1 }
    }

    /// What the lookup bar says about the word being typed, before Return.
    enum Preview: Equatable {
        /// The word book has a card for it: its meanings.
        case kept(String)
        /// This Mac's translation.
        case device(String)
    }

    @Published var shelf: Shelf = .all { didSet { if shelf != oldValue { reload() } } }
    @Published var filterText = "" { didSet { if filterText != oldValue { reload() } } }
    @Published var sort: AskWordBookQuery.Sort = .recent { didSet { if sort != oldValue { reload() } } }
    @Published private(set) var entries: [AskWordBookEntry] = []
    @Published var selectedKey: String? { didSet { if selectedKey != nil, selectedKey != oldValue { transient = nil } } }
    @Published private(set) var pairs: [AskWordBookLanguagePair] = []
    @Published private(set) var counts: [Shelf: Int] = [:]
    /// Days in a row with a lookup, ending today (or yesterday, until today has one).
    @Published private(set) var streak = 0
    /// Lookups on each day of this week, Monday first.
    @Published private(set) var week: [Int] = Array(repeating: 0, count: 7)
    /// What was just deleted, for undo.
    @Published private(set) var deleted: [AskWordBookEntry] = []
    /// A short message at the bottom: copied, deleted, exported, or what went wrong.
    @Published var notice: String?
    @Published private(set) var regenerating: String?
    @Published var recordsHistory: Bool {
        didSet { settings.askWordBookRecordsHistory = recordsHistory }
    }

    @Published var retention: AskWordBookRetention {
        didSet {
            settings.askWordBookRetention = retention
            purgeExpired()
        }
    }

    // MARK: Lookup

    @Published var lookupText = ""
    @Published private(set) var preview: Preview?
    /// The word whose card the AI is writing.
    @Published private(set) var lookingUp: String?
    /// A result kept out of the book: a sentence, or any lookup while history is off.
    @Published private(set) var transient: AskWordBookEntry?
    /// The key of a word the last lookup added, for its "new" badge.
    @Published private(set) var freshKey: String?
    /// A target language chosen with ⇥; nil follows the usual direction.
    @Published var targetPreset: String?

    let store: any AskWordBookStoring
    private let settings: SettingsStore
    /// Writes a new card for a word; nil without a text-processing model.
    var dictionary: (any AskWordLookingUp)?
    /// The lookup bar's preview while typing; it never leaves the Mac.
    var onDevice: any AskTranslationEngine = AskOnDeviceTranslationEngine()
    var detector: any AskLanguageDetecting = AskLanguageDetector()
    var interfaceLanguage: () -> AppLanguage = { AppLocalization.shared.language }
    var modelName: () -> String = { "AI" }
    var speakText: @MainActor (String, String) -> Void = { text, language in
        AskSpeaker.shared.speak(text, language: language)
    }
    var copy: (String) -> Void = { AskQuickResults.copy($0) }
    /// Asks where to save an export; nil when cancelled. Tests answer it.
    var chooseExportURL: @MainActor (String) -> URL? = AskWordBookViewModel.askForExportURL
    /// Opens a conversation about a word; the window controller supplies it.
    var askAI: (@MainActor (String) -> Void)?
    var now: () -> Date = Date.init
    var calendar = Calendar.current
    static let pageSize = 200
    /// How far back the streak looks.
    static let streakDays = 60
    private var limit = AskWordBookViewModel.pageSize
    private var observer: NSObjectProtocol?

    init(store: any AskWordBookStoring, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        recordsHistory = settings.askWordBookRecordsHistory
        retention = settings.askWordBookRetention
        observer = NotificationCenter.default.addObserver(forName: .askWordBookDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Shelves and list

    /// The words on `shelf`; `filtered` applies the list's filter (the sidebar counts do not).
    func query(for shelf: Shelf, limit: Int? = nil, filtered: Bool = true) -> AskWordBookQuery {
        var query = AskWordBookQuery(text: filtered ? filterText : "", sort: sort, limit: limit ?? self.limit)
        switch shelf {
        case .all: break
        case .starred: query.scope = .starred
        case .today: query.since = calendar.startOfDay(for: now())
        case .week: query.since = weekStart
        case let .pair(pair): query.pair = pair
        }
        return query
    }

    private var weekStart: Date {
        var monday = calendar
        monday.firstWeekday = 2
        return monday.dateInterval(of: .weekOfYear, for: now())?.start ?? calendar.startOfDay(for: now())
    }

    var selected: AskWordBookEntry? { entries.first { $0.key == selectedKey } ?? selectedKey.flatMap(store.entry(forKey:)) }

    /// What the detail shows: a fresh result kept out of the book, or the chosen word.
    var displayed: AskWordBookEntry? { transient ?? selected }

    /// Day headings when the list is in date order; one unnamed section otherwise.
    var sections: [Section] {
        guard sort == .recent, !entries.isEmpty else {
            return entries.isEmpty ? [] : [Section(period: nil, entries: entries)]
        }
        let today = now()
        var sections: [Section] = []
        for entry in entries {
            let period = Period.of(entry.lastLookedUpAt, now: today, calendar: calendar)
            if sections.last?.period == period {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(Section(period: period, entries: [entry]))
            }
        }
        return sections
    }

    func reload() {
        entries = store.list(query(for: shelf))
        pairs = store.languagePairs()
        var counts: [Shelf: Int] = [:]
        for shelf in [Shelf.all, .starred, .today, .week] + pairs.map(Shelf.pair) {
            counts[shelf] = store.count(matching: query(for: shelf, filtered: false))
        }
        self.counts = counts
        if case let .pair(pair) = shelf, !pairs.contains(pair) { shelf = .all }
        updateActivity()
        if transient == nil, selectedKey == nil || !entries.contains(where: { $0.key == selectedKey }) {
            selectedKey = entries.first?.key
        }
    }

    private func updateActivity() {
        let today = calendar.startOfDay(for: now())
        let since = calendar.date(byAdding: .day, value: -Self.streakDays, to: today) ?? today
        let dates = store.activity(since: since)
        let days = Set(dates.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day ?? -1 })
        var day = days.contains(0) ? 0 : 1
        var run = 0
        while days.contains(day) {
            run += 1
            day += 1
        }
        streak = run
        let start = weekStart
        var week = Array(repeating: 0, count: 7)
        for date in dates where date >= start {
            let index = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? -1
            if week.indices.contains(index) { week[index] += 1 }
        }
        self.week = week
    }

    /// Words in the book looked up this week.
    var weekTotal: Int { counts[.week] ?? 0 }

    /// Today's place in `week` (Monday is 0), so the bars can mark it.
    var todayIndex: Int {
        calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: now())).day ?? 0
    }

    /// The list reached its end: show the next page.
    func loadMore() {
        guard entries.count >= limit else { return }
        limit += Self.pageSize
        reload()
    }

    /// Shows a word where it lives: the current shelf when it is there, else all words.
    func reveal(_ key: String?) {
        guard let key, store.entry(forKey: key) != nil else { return }
        transient = nil
        filterText = ""
        reload()
        if !entries.contains(where: { $0.key == key }) {
            shelf = .all
            sort = .recent
            reload()
        }
        selectedKey = key
    }

    /// ↑ / ↓ through the list.
    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.key == selectedKey && transient == nil } ?? (delta > 0 ? -1 : entries.count)
        selectedKey = entries[min(max(0, index + delta), entries.count - 1)].key
        transient = nil
    }

    func title(of shelf: Shelf) -> String {
        switch shelf {
        case .all: L("ask.wordBook.shelf.all")
        case .starred: L("ask.wordBook.shelf.starred")
        case .today: L("ask.wordBook.shelf.today")
        case .week: L("ask.wordBook.shelf.week")
        case let .pair(pair): Self.pairTitle(pair, in: interfaceLanguage())
        }
    }

    // MARK: - Looking up

    /// The language `text` is in and the one it goes into.
    func direction(for text: String) -> (source: String?, target: String) {
        let language = interfaceLanguage()
        let primary = AskTranslationLanguages.code(for: language)
        let second = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
        let source = text.isEmpty ? nil : detector.detect(text, hints: [primary, second])
        let target = AskTranslationLanguages.target(source: source, primary: primary, second: second, preset: targetPreset)
        return (source, target)
    }

    /// "English → Simplified Chinese" for what is typed, or "→ Simplified Chinese".
    var directionTitle: String {
        let text = lookupText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (source, target) = direction(for: text)
        return Self.pairTitle(AskWordBookLanguagePair(source: source, target: target), in: interfaceLanguage())
    }

    /// ⇥: the next target language.
    func cycleTarget() {
        let language = interfaceLanguage()
        let primary = AskTranslationLanguages.code(for: language)
        let second = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
        let (source, target) = direction(for: lookupText.trimmingCharacters(in: .whitespacesAndNewlines))
        targetPreset = AskTranslationLanguages.step(from: target, by: 1, primary: primary, second: second, skipping: source)
    }

    /// While typing: the kept card's meanings, or this Mac's translation; nothing leaves the Mac.
    func refreshPreview() async {
        let text = lookupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { preview = nil; return }
        let (source, target) = direction(for: text)
        if let entry = store.entry(forKey: AskWordBookEntry.key(headword: text, source: source, target: target)),
           entry.lookup.card != nil {
            preview = .kept(entry.lookup.summary)
            return
        }
        guard await onDevice.canTranslate(from: source, to: target),
              let translation = try? await onDevice.translate(text, from: source, to: target),
              text == lookupText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            if text == lookupText.trimmingCharacters(in: .whitespacesAndNewlines) { preview = nil }
            return
        }
        preview = .device(translation)
    }

    /// Return in the lookup bar (or `dict word` from the launcher): a card the book
    /// keeps opens at once; otherwise the AI writes one, and a word or phrase goes into
    /// the book while history is on.
    func lookUp(_ text: String? = nil) async {
        let word = (text ?? lookupText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, lookingUp == nil else { return }
        lookupText = word
        preview = nil
        freshKey = nil
        let (source, target) = direction(for: word)
        let key = AskWordBookEntry.key(headword: word, source: source, target: target)
        if let entry = store.entry(forKey: key), entry.lookup.card != nil {
            if recordsHistory { store.record(entry.lookup, at: now(), counts: true) }
            reveal(key)
            return
        }
        guard let dictionary else {
            notice = L("ask.plugin.translate.noModel")
            return
        }
        lookingUp = word
        transient = nil
        defer { lookingUp = nil }
        do {
            let reply = try await dictionary.lookUp(word, from: source, to: target, generation: "0")
            switch reply {
            case let .card(card):
                let lookup = AskWordBookLookup(headword: word, source: source, target: target, card: card,
                                               model: modelName())
                if recordsHistory, AskWordCard.isLookup(word) {
                    let known = store.entry(forKey: key) != nil
                    store.record(lookup, at: now(), counts: true)
                    reveal(key)
                    freshKey = known ? nil : key
                } else {
                    transient = loose(lookup)
                }
            case let .translation(translation), let .unreadable(translation):
                transient = loose(AskWordBookLookup(headword: word, source: source, target: target,
                                                    translation: translation, model: modelName()))
            }
        } catch {
            notice = (error as? AskPluginFailure)?.message ?? error.localizedDescription
        }
    }

    /// A result shown without being kept.
    private func loose(_ lookup: AskWordBookLookup) -> AskWordBookEntry {
        AskWordBookEntry(id: UUID(), lookup: lookup, lookupCount: 1, firstLookedUpAt: now(), lastLookedUpAt: now(),
                         starredAt: nil)
    }

    /// Whether `entry` is shown without being in the book.
    func isTransient(_ entry: AskWordBookEntry) -> Bool { transient?.id == entry.id }

    // MARK: - Changes

    func toggleStar(_ entry: AskWordBookEntry) {
        let starred = !entry.isStarred
        store.setStarred(starred, lookup: entry.lookup, at: now())
        notice = L(starred ? "ask.wordBook.starred" : "ask.wordBook.unstarred", entry.headword)
        if isTransient(entry) {
            transient = nil
            reveal(entry.key)
        } else {
            reload()
        }
    }

    /// Deletes the entry; `undoDelete` brings it back. A loose result is just dismissed.
    func delete(_ entry: AskWordBookEntry) {
        if isTransient(entry) {
            transient = nil
            return
        }
        let index = entries.firstIndex { $0.key == entry.key }
        store.delete(keys: [entry.key])
        deleted = [entry]
        notice = L("ask.wordBook.deleted", entry.headword)
        reload()
        if let index, !entries.isEmpty { selectedKey = entries[min(index, entries.count - 1)].key }
    }

    func undoDelete() {
        guard !deleted.isEmpty else { return }
        store.restore(deleted)
        selectedKey = deleted.first?.key
        deleted = []
        notice = nil
        reload()
    }

    func copyMeaning(_ entry: AskWordBookEntry) {
        copyText(entry.lookup.firstMeaning ?? entry.lookup.summary)
    }

    func copyText(_ text: String) {
        copy(text)
        notice = L("ask.wordBook.copied", text)
    }

    func speak(_ entry: AskWordBookEntry) {
        speakText(entry.headword, Self.spokenLanguage(entry))
    }

    static func spokenLanguage(_ entry: AskWordBookEntry) -> String {
        entry.lookup.source ?? (AskWordCard.containsCJK(entry.headword) ? "zh-Hans" : "en")
    }

    func ask(about entry: AskWordBookEntry) {
        let text = entry.lookup.card?.markdown ?? "**\(entry.headword)**\n\(entry.lookup.translation ?? "")"
        askAI?(L("ask.plugin.translate.askAI.word", text))
    }

    var canRegenerate: Bool { dictionary != nil }

    /// Asks the AI for a new card and keeps it, without counting a lookup.
    func regenerate(_ entry: AskWordBookEntry) async {
        guard let dictionary, regenerating == nil else { return }
        regenerating = entry.key
        defer { regenerating = nil }
        do {
            let reply = try await dictionary.lookUp(entry.headword, from: entry.lookup.source, to: entry.lookup.target,
                                                    generation: UUID().uuidString)
            guard case let .card(card) = reply else {
                notice = L("ask.wordBook.regenerate.failed")
                return
            }
            var lookup = entry.lookup
            lookup.card = card
            lookup.model = modelName()
            if isTransient(entry) {
                transient = loose(lookup)
            } else {
                store.record(lookup, at: now(), counts: false)
                reload()
            }
            notice = L("ask.wordBook.regenerated", entry.headword)
        } catch {
            notice = (error as? AskPluginFailure)?.message ?? error.localizedDescription
        }
    }

    /// Saves what the list shows now (filter and shelf apply) in `format`.
    func export(_ format: AskWordBookExporter.Format) {
        let all = store.list(query(for: shelf, limit: .max))
        guard !all.isEmpty else { return }
        let name = L("ask.wordBook.title") + "." + format.fileExtension
        guard let url = chooseExportURL(name) else { return }
        do {
            try AskWordBookExporter.export(all, as: format).write(to: url, atomically: true, encoding: .utf8)
            notice = L("ask.wordBook.exported", all.count)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Removes every lookup that is not starred.
    func clearHistory() {
        store.purgeHistory(before: nil)
        reload()
    }

    func purgeExpired() {
        guard let cutoff = retention.cutoff(now: now()) else { return }
        store.purgeHistory(before: cutoff)
        reload()
    }

    static func askForExportURL(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// "English → Simplified Chinese".
    static func pairTitle(_ pair: AskWordBookLanguagePair, in language: AppLanguage) -> String {
        let target = AskTranslationLanguages.name(pair.target, in: language)
        guard let source = pair.source else { return "→ " + target }
        return AskTranslationLanguages.name(source, in: language) + " → " + target
    }
}
