import Foundation

/// Scores applications against the launcher's text. Pure, so the ranking can
/// be tested without the applications installed on this Mac.
enum AskAppMatcher {
    /// Below this an application is not listed at all.
    static let minimumScore = 0.45
    /// From this an application may take Return, see `isStrong`.
    static let strongScore = 0.8
    static let maximumQueryLength = 40

    /// How well `query` names `entry`, or nil when it does not.
    static func score(_ query: String, _ entry: AskAppEntry, fuzzy: Bool = true) -> Double? {
        match(AskSearchQuery(query), entry, fuzzy: fuzzy)?.score
    }

    /// The best of `entry`'s names for `query`, with the characters of its shown name that matched.
    static func match(_ query: AskSearchQuery, _ entry: AskAppEntry, fuzzy: Bool = true,
                      highlights: Bool = false) -> AskAppMatch? {
        // "wechat?" still lists WeChat; `isStrong` decides whether a question takes Return.
        guard query.isSearchable, query.text.count <= maximumQueryLength else { return nil }
        var best: (score: Double, ranges: [Range<Int>], shown: Bool)?
        for (index, key) in entry.keys.enumerated() {
            guard let found = AskFuzzyMatcher.match(query.compact, key, fuzzy: fuzzy, ranges: highlights && index == 0),
                  found.score > (best?.score ?? 0) else { continue }
            best = (found.score, found.ranges, index == 0)
            if found.score == AskFuzzyMatcher.exact { break }
        }
        guard let best else { return nil }
        // A single letter only lists names that start with it.
        if query.compact.count == 1, best.score < AskFuzzyMatcher.wordPrefix { return nil }
        guard best.score >= minimumScore else { return nil }
        let ranges = best.shown && highlights ? AskSearchText.characterRanges(best.ranges, in: entry.name) : []
        return AskAppMatch(entry: entry, score: best.score, highlights: ranges)
    }

    /// The best `limit` matches, with launch counts from the launcher nudging
    /// the ones the user opens most. Ties go to the shorter name.
    static func search(_ query: String, in entries: [AskAppEntry], launches: [String: Int] = [:],
                       limit: Int = 5, fuzzy: Bool = true) -> [AskAppMatch] {
        let parsed = AskSearchQuery(query)
        guard parsed.isSearchable else { return [] }
        return entries.compactMap { entry -> AskAppMatch? in
            guard var found = match(parsed, entry, fuzzy: fuzzy, highlights: true) else { return nil }
            found.score += Double(min(launches[entry.id] ?? 0, 10)) * 0.005
            return found
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.name.count != $1.entry.name.count { return $0.entry.name.count < $1.entry.name.count }
            return $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Whether the top match may take Return from "Ask AI": a short query
    /// that clearly names it. Questions and sentences stay with the AI.
    static func isStrong(_ match: AskAppMatch?, query: String) -> Bool {
        guard let match, match.score >= strongScore else { return false }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.split(separator: " ").count <= 3 else { return false }
        return !text.contains { "?？。，,!！:：;；".contains($0) }
    }
}
