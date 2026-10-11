import Foundation

/// Usage counts and last-use times rank the launcher keywords. The older
/// decaying score remains available for compatibility with existing callers.
struct AskKeywordUsage: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var score: Double
        var lastUsed: Date
        var count: Int = 0

        private enum CodingKeys: String, CodingKey { case score, lastUsed, count }

        init(score: Double, lastUsed: Date, count: Int = 0) {
            self.score = score
            self.lastUsed = lastUsed
            self.count = count
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            score = try values.decode(Double.self, forKey: .score)
            lastUsed = try values.decode(Date.self, forKey: .lastUsed)
            // Older versions stored a decaying score only; keep its best available estimate.
            count = try values.decodeIfPresent(Int.self, forKey: .count) ?? max(1, Int(score.rounded(.up)))
        }
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
        entries[id] = Entry(score: previous + 1, lastUsed: max(date, entries[id]?.lastUsed ?? date),
                            count: (entries[id]?.count ?? 0) + 1)
        guard entries.count > Self.maximumEntries else { return }
        let ranked = entries.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.value.lastUsed > $1.value.lastUsed
        }
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
