import AppKit
import Foundation

/// What the word book dialog shows and does: the starred words or every lookup,
/// searched, filtered and sorted; the chosen one; and the changes made to them.
@MainActor
final class AskWordBookViewModel: ObservableObject {
    /// A day heading in the lookup history.
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

    struct Section: Identifiable, Equatable {
        var period: Period?
        var entries: [AskWordBookEntry]
        var id: Int { period?.rawValue ?? -1 }
    }

    @Published var scope: AskWordBookQuery.Scope = .starred { didSet { if scope != oldValue { reload() } } }
    @Published var searchText = "" { didSet { if searchText != oldValue { reload() } } }
    @Published var pair: AskWordBookLanguagePair? { didSet { if pair != oldValue { reload() } } }
    @Published var sort: AskWordBookQuery.Sort = .recent { didSet { if sort != oldValue { reload() } } }
    @Published private(set) var entries: [AskWordBookEntry] = []
    @Published var selectedKey: String?
    @Published private(set) var pairs: [AskWordBookLanguagePair] = []
    @Published private(set) var starredCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var recentCount = 0
    /// What was just deleted, for undo.
    @Published private(set) var deleted: [AskWordBookEntry] = []
    /// A short message at the bottom: deleted, exported, or what went wrong.
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

    let store: any AskWordBookStoring
    private let settings: SettingsStore
    /// Writes a new card for a word; nil without a text-processing model.
    var dictionary: (any AskWordLookingUp)?
    var modelName: () -> String = { "AI" }
    var speakText: @MainActor (String, String) -> Void = { text, language in
        AskSpeaker.shared.speak(text, language: language)
    }
    var copy: (String) -> Void = { AskQuickResults.copy($0) }
    /// Asks where to save an export; nil when cancelled. Tests answer it.
    var chooseExportURL: @MainActor (String) -> URL? = AskWordBookViewModel.askForExportURL
    var now: () -> Date = Date.init
    static let pageSize = 200
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

    var query: AskWordBookQuery {
        AskWordBookQuery(scope: scope, text: searchText, pair: pair, sort: sort, limit: limit)
    }

    var selected: AskWordBookEntry? { entries.first { $0.key == selectedKey } }

    /// The history by day when it is in date order; one unnamed section otherwise.
    var sections: [Section] {
        guard scope == .all, sort == .recent, !entries.isEmpty else {
            return entries.isEmpty ? [] : [Section(period: nil, entries: entries)]
        }
        let today = now()
        var sections: [Section] = []
        for entry in entries {
            let period = Period.of(entry.lastLookedUpAt, now: today)
            if sections.last?.period == period {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(Section(period: period, entries: [entry]))
            }
        }
        return sections
    }

    func reload() {
        entries = store.list(query)
        pairs = store.languagePairs()
        starredCount = store.count(.starred)
        totalCount = store.count(.all)
        recentCount = store.lookups(since: now().addingTimeInterval(-7 * 24 * 3600))
        if selectedKey == nil || selected == nil { selectedKey = entries.first?.key }
    }

    /// The list reached its end: show the next page.
    func loadMore() {
        guard entries.count >= limit else { return }
        limit += Self.pageSize
        reload()
    }

    /// Opens on a word: the starred list when it is starred, the history otherwise, unfiltered.
    func reveal(_ key: String?) {
        guard let key, let entry = store.entry(forKey: key) else { return }
        searchText = ""
        pair = nil
        scope = entry.isStarred ? .starred : .all
        reload()
        if !entries.contains(where: { $0.key == key }) {
            sort = .recent
            reload()
        }
        selectedKey = key
    }

    /// ↑ / ↓ through the list.
    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.key == selectedKey } ?? (delta > 0 ? -1 : entries.count)
        selectedKey = entries[min(max(0, index + delta), entries.count - 1)].key
    }

    func toggleStar(_ entry: AskWordBookEntry) {
        store.setStarred(!entry.isStarred, lookup: entry.lookup, at: now())
        reload()
    }

    /// Deletes the entry; `undoDelete` brings it back.
    func delete(_ entry: AskWordBookEntry) {
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
        copy(entry.lookup.firstMeaning ?? entry.lookup.summary)
        notice = L("ask.plugin.copied")
    }

    func speak(_ entry: AskWordBookEntry) {
        let language = entry.lookup.source ?? (AskWordCard.containsCJK(entry.headword) ? "zh-Hans" : "en")
        speakText(entry.headword, language)
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
            store.record(lookup, at: now(), counts: false)
            notice = L("ask.wordBook.regenerated", entry.headword)
            reload()
        } catch {
            notice = (error as? AskPluginFailure)?.message ?? error.localizedDescription
        }
    }

    /// Saves what the list shows now (search and filters apply) in `format`.
    func export(_ format: AskWordBookExporter.Format) {
        let all = store.list(AskWordBookQuery(scope: scope, text: searchText, pair: pair, sort: sort, limit: .max))
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
