import Foundation

/// Scan storage pages off the main thread, retaining the raw cursor so sparse filters
/// neither hide later matches nor skip records at the end of a partially consumed page.
enum HistorySettingsQuery {
    struct Page {
        let records: [HistoryRecord]
        let nextOffset: Int
        let hasMore: Bool
    }

    static func page(store: HistoryStore, query: String?, filter: HistorySettingsFilter,
                     limit: Int, offset: Int) -> Page {
        guard limit > 0 else { return Page(records: [], nextOffset: max(0, offset), hasMore: false) }
        var cursor = max(0, offset)
        var matches: [HistoryRecord] = []
        while true {
            let records = store.list(limit: limit, offset: cursor, searchQuery: query)
            for (index, record) in records.enumerated() {
                cursor += 1
                if filter.matches(record) {
                    matches.append(record)
                }
                if matches.count == limit {
                    return Page(records: matches, nextOffset: cursor,
                                hasMore: index < records.count - 1 || records.count == limit)
                }
            }
            if records.count < limit {
                return Page(records: matches, nextOffset: cursor, hasMore: false)
            }
        }
    }
}
