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
    static func score(_ query: String, _ entry: AskAppEntry) -> Double? {
        guard query.count <= maximumQueryLength, !query.contains(where: \.isNewline) else { return nil }
        // "wechat?" still lists WeChat; `isStrong` decides whether a question takes Return.
        let text = query.filter { !$0.isPunctuation }.trimmingCharacters(in: .whitespaces).lowercased()
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        var best = 0.0
        for name in entry.names {
            let flat = name.filter { !$0.isWhitespace }
            if name == text || flat == compact {
                best = max(best, 1)
            } else if flat.hasPrefix(compact) {
                best = max(best, 0.9)
            } else if words(of: name).contains(where: { $0.hasPrefix(compact) }) {
                best = max(best, 0.82)
            } else if compact.count >= 2, flat.contains(compact) {
                best = max(best, 0.6)
            } else if compact.count >= 3, isSubsequence(compact, of: flat) {
                best = max(best, 0.45)
            }
        }
        if compact.count >= 2 {
            for initials in entry.initials + entry.pinyinInitials {
                if initials == compact { best = max(best, 0.88) } else if initials.hasPrefix(compact) { best = max(best, 0.8) }
            }
            for spelling in entry.pinyin {
                if spelling == compact { best = max(best, 0.95) } else if spelling.hasPrefix(compact) { best = max(best, 0.86) }
            }
        }
        // A single letter only lists names that start with it.
        if compact.count == 1, best < 0.82 { return nil }
        return best >= minimumScore ? best : nil
    }

    /// The best `limit` matches, with launch counts from the launcher nudging
    /// the ones the user opens most. Ties go to the shorter name.
    static func search(_ query: String, in entries: [AskAppEntry], launches: [String: Int] = [:],
                       limit: Int = 5) -> [AskAppMatch] {
        entries.compactMap { entry -> AskAppMatch? in
            guard let score = score(query, entry) else { return nil }
            let boost = Double(min(launches[entry.id] ?? 0, 10)) * 0.005
            return AskAppMatch(entry: entry, score: score + boost)
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

    private static func words(of name: String) -> [String] {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for char in haystack where char == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
