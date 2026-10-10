import Foundation

/// A local feature discoverable before entering keyword mode.
struct AskLauncherSearchEntry: Equatable, Sendable, Identifiable {
    var keyword: AskKeyword
    var title: String
    var detail: String
    var symbol: String
    var command: AskSystemCommand?
    var alternateNames: [String] = []

    var id: String {
        keyword.pluginID + ":" + keyword.id
    }

    private struct RankedEntry {
        var rank: Int
        var order: Int
        var entry: AskLauncherSearchEntry
    }

    static func search(_ entries: [Self], text: String, limit: Int = 6) -> [Self] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty, !AskSearchQuery(text).hasFilters else { return [] }
        return entries.enumerated().compactMap { index, entry -> RankedEntry? in
            guard entry.keyword.enabled else { return nil }
            let fields = ((entry.keyword.allKeywords + [entry.title]) + entry
                .alternateNames + (entry.command?.searchNames ?? []))
                .filter { !$0.isEmpty }.map { $0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) }
            let rank: Int
            if fields.contains(query) {
                rank = 0
            } else if fields.contains(where: { $0.hasPrefix(query) }) {
                rank = 1
            } else if fields.contains(where: { $0.contains(query) }) {
                rank = 2
            } else {
                return nil
            }
            return RankedEntry(rank: rank, order: index, entry: entry)
        }.sorted { $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank }
            .reduce(into: [Self]()) { result, match in
                // A command with multiple aliases still appears only once.
                if result.count < limit, !result.contains(where: { $0.id == match.entry.id ||
                        (match.entry.command != nil && $0.command == match.entry.command)
                }) { result.append(match.entry) }
            }
    }
}
