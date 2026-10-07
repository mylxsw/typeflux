import Foundation

/// How much each launcher keyword has been used lately, so the launcher can
/// offer the ones a person actually reaches for. Each use adds one to a score
/// that halves every two weeks, so habits that changed fade out on their own.
struct AskKeywordUsage: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var score: Double
        var lastUsed: Date
    }

    /// By `AskKeyword.id`.
    var entries: [String: Entry] = [:]

    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// The most keywords kept; the least used go first.
    static let maximumEntries = 64

    static func decayed(_ entry: Entry, at date: Date) -> Double {
        let age = max(0, date.timeIntervalSince(entry.lastUsed))
        return entry.score * pow(0.5, age / halfLife)
    }

    mutating func record(_ id: String, at date: Date) {
        let previous = entries[id].map { Self.decayed($0, at: date) } ?? 0
        entries[id] = Entry(score: previous + 1, lastUsed: max(date, entries[id]?.lastUsed ?? date))
        guard entries.count > Self.maximumEntries else { return }
        let ranked = entries.sorted { Self.decayed($0.value, at: date) > Self.decayed($1.value, at: date) }
        entries = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.maximumEntries).map { ($0.key, $0.value) })
    }

    /// Each keyword's score as of `date`.
    func scores(at date: Date) -> [String: Double] {
        entries.mapValues { Self.decayed($0, at: date) }
    }
}

/// Keeps `AskKeywordUsage` in the user's defaults. It never leaves this Mac.
@MainActor
final class AskKeywordUsageStore {
    static let defaultsKey = "ask.launcher.keywordUsage"

    private let defaults: UserDefaults
    private(set) var usage: AskKeywordUsage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        usage = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AskKeywordUsage.self, from: $0) } ?? AskKeywordUsage()
    }

    func record(_ keyword: AskKeyword, at date: Date = Date()) {
        usage.record(keyword.id, at: date)
        if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func scores(at date: Date = Date()) -> [String: Double] { usage.scores(at: date) }
}
