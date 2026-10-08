import Foundation

/// A word or short phrase the translation plugin looked up, as the word book keeps
/// it: an AI word card, or the short translation this Mac gave
/// (`docs/design/translation-word-book.md`).
struct AskWordBookLookup: Equatable, Sendable {
    var headword: String
    var source: String?
    var target: String
    var card: AskWordCard?
    var translation: String?
    /// The model that wrote the card, for display only.
    var model: String?

    var key: String { AskWordBookEntry.key(headword: headword, source: source, target: target) }

    /// One line of meanings: `n. 机缘巧合；意外的好运  v. …`, or the translation.
    var summary: String {
        if let card, !card.senses.isEmpty {
            return card.senses.map { sense in
                [sense.pos, sense.meanings.joined(separator: AskWordCard.meaningSeparator)]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "  ")
        }
        return translation ?? ""
    }

    /// What ⌥↩ writes: the card's concise translation, or the translation's first part.
    var firstMeaning: String? {
        if let meaning = card?.translatedText { return meaning }
        let first = translation?.components(separatedBy: CharacterSet(charactersIn: "；;,，")).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return first?.isEmpty == false ? first : nil
    }
}

/// A row of the word book: what was looked up, how often, and whether it is starred.
struct AskWordBookEntry: Equatable, Sendable, Identifiable {
    var id: UUID
    var lookup: AskWordBookLookup
    var lookupCount: Int
    var firstLookedUpAt: Date
    var lastLookedUpAt: Date
    var starredAt: Date?

    var key: String { lookup.key }
    var headword: String { lookup.headword }
    var isStarred: Bool { starredAt != nil }

    /// The same word in the same direction: spacing and case folded, languages by their base
    /// (`en-US` is `en`; Simplified and Traditional Chinese stay apart). The model is not part of it.
    static func key(headword: String, source: String?, target: String) -> String {
        let word = headword.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return [word, source.map(AskTranslationLanguages.base) ?? "", AskTranslationLanguages.base(target)]
            .joined(separator: "|")
    }
}

/// Which entries the word book lists, and in what order.
struct AskWordBookQuery: Equatable, Sendable {
    enum Scope: String, CaseIterable, Sendable {
        case starred, all
    }

    enum Sort: String, CaseIterable, Sendable {
        /// Last looked up first.
        case recent
        case count
        case alphabetical
        /// Starred most recently first.
        case starred
    }

    var scope: Scope = .all
    /// Matches the word or its meanings.
    var text = ""
    var pair: AskWordBookLanguagePair?
    /// Only words last looked up since then (today, this week).
    var since: Date?
    var sort: Sort = .recent
    var limit = 100
    var offset = 0
}

/// A translation direction the word book holds entries for.
struct AskWordBookLanguagePair: Hashable, Sendable {
    var source: String?
    var target: String
}

/// How long lookups that are not starred stay in the word book.
enum AskWordBookRetention: String, CaseIterable, Sendable {
    case week, month, quarter, forever

    static let `default` = AskWordBookRetention.quarter

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .forever: nil
        }
    }

    /// Lookups older than this go; nil keeps them all.
    func cutoff(now: Date) -> Date? {
        days.map { now.addingTimeInterval(-TimeInterval($0) * 24 * 3600) }
    }
}

/// The word book's storage. Every call is synchronous and safe from any thread;
/// changes are announced with `.askWordBookDidChange` on the main queue.
protocol AskWordBookStoring: AnyObject, Sendable {
    func entry(forKey key: String) -> AskWordBookEntry?
    /// Adds the lookup, or updates its entry: a newer card replaces the old one, and a
    /// translation never replaces a card. `counts` adds one to the times it was looked up.
    @discardableResult
    func record(_ lookup: AskWordBookLookup, at date: Date, counts: Bool) -> AskWordBookEntry?
    /// Stars or unstars the word, adding it first when starring a word not kept yet.
    @discardableResult
    func setStarred(_ starred: Bool, lookup: AskWordBookLookup, at date: Date) -> AskWordBookEntry?
    func list(_ query: AskWordBookQuery) -> [AskWordBookEntry]
    func count(_ scope: AskWordBookQuery.Scope) -> Int
    /// How many entries `query` matches, ignoring its sort and paging.
    func count(matching query: AskWordBookQuery) -> Int
    /// When words were first and last looked up, for those last looked up since `date`.
    func activity(since date: Date) -> [Date]
    /// Words last looked up since `date`.
    func lookups(since date: Date) -> Int
    func languagePairs() -> [AskWordBookLanguagePair]
    func delete(keys: [String])
    /// Puts deleted entries back as they were (undo).
    func restore(_ entries: [AskWordBookEntry])
    /// Removes lookups that are not starred, all of them or those last looked up before `date`.
    func purgeHistory(before date: Date?)
}

extension Notification.Name {
    static let askWordBookDidChange = Notification.Name("askWordBookDidChange")
}

/// Records what the translation plugin looked up, once per launcher session, while
/// the user lets it. A word seen again in the same session only has its card updated.
@MainActor
final class AskWordBookRecorder {
    let store: any AskWordBookStoring
    var isEnabled: () -> Bool
    var now: () -> Date = Date.init
    private var recorded: Set<String> = []

    init(store: any AskWordBookStoring, isEnabled: @escaping () -> Bool = { true }) {
        self.store = store
        self.isEnabled = isEnabled
    }

    /// A new launcher session: every word counts again.
    func beginSession() { recorded.removeAll() }

    func record(_ lookup: AskWordBookLookup) {
        guard isEnabled(), !lookup.headword.isEmpty else { return }
        let first = recorded.insert(lookup.key).inserted
        store.record(lookup, at: now(), counts: first)
    }

    func isStarred(_ key: String) -> Bool { store.entry(forKey: key)?.isStarred == true }

    /// Stars or unstars the word; returns whether it is starred now.
    @discardableResult
    func toggleStar(_ lookup: AskWordBookLookup) -> Bool {
        let starred = !isStarred(lookup.key)
        store.setStarred(starred, lookup: lookup, at: now())
        return starred
    }
}
