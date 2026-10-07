import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The word book in `word-book.sqlite`, next to the history database. One table
/// holds every lookup; a starred word is one with `starred_at` set.
final class SQLiteAskWordBookStore: AskWordBookStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ask.wordbook.sqlite")
    private var db: OpaquePointer?
    /// Where change notifications go; tests count them.
    var notificationCenter: NotificationCenter = .default

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite(message) }
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try execute("""
            CREATE TABLE IF NOT EXISTS word_book_entries (
                id TEXT PRIMARY KEY NOT NULL,
                lookup_key TEXT NOT NULL UNIQUE,
                headword TEXT NOT NULL,
                source_language TEXT,
                target_language TEXT NOT NULL,
                card_json BLOB,
                translation TEXT,
                summary TEXT NOT NULL,
                model TEXT,
                lookup_count INTEGER NOT NULL DEFAULT 1,
                first_looked_up_at REAL NOT NULL,
                last_looked_up_at REAL NOT NULL,
                starred_at REAL
            );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_word_book_last ON word_book_entries(last_looked_up_at DESC);")
            try execute("CREATE INDEX IF NOT EXISTS idx_word_book_starred ON word_book_entries(starred_at DESC);")
        } catch {
            ErrorLogStore.shared.log("Word book database initialization failed: \(error.localizedDescription)")
        }
    }

    /// `~/Library/Application Support/Typeflux/word-book.sqlite`.
    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Typeflux", isDirectory: true).appendingPathComponent("word-book.sqlite")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - AskWordBookStoring

    func entry(forKey key: String) -> AskWordBookEntry? {
        read("entry") { () throws -> AskWordBookEntry? in try fetch(where: "lookup_key = ?", [.text(key)]).first } ?? nil
    }

    @discardableResult
    func record(_ lookup: AskWordBookLookup, at date: Date, counts: Bool) -> AskWordBookEntry? {
        write("record") { () throws -> AskWordBookEntry? in
            if var entry = try fetch(where: "lookup_key = ?", [.text(lookup.key)]).first {
                Self.merge(lookup, into: &entry)
                if counts {
                    entry.lookupCount += 1
                    entry.lastLookedUpAt = date
                }
                try upsert(entry)
                return entry
            }
            let entry = AskWordBookEntry(id: UUID(), lookup: lookup, lookupCount: 1, firstLookedUpAt: date,
                                         lastLookedUpAt: date, starredAt: nil)
            try upsert(entry)
            return entry
        } ?? nil
    }

    @discardableResult
    func setStarred(_ starred: Bool, lookup: AskWordBookLookup, at date: Date) -> AskWordBookEntry? {
        write("star") { () throws -> AskWordBookEntry? in
            if var entry = try fetch(where: "lookup_key = ?", [.text(lookup.key)]).first {
                Self.merge(lookup, into: &entry)
                entry.starredAt = starred ? (entry.starredAt ?? date) : nil
                try upsert(entry)
                return entry
            }
            guard starred else { return nil }
            let entry = AskWordBookEntry(id: UUID(), lookup: lookup, lookupCount: 1, firstLookedUpAt: date,
                                         lastLookedUpAt: date, starredAt: date)
            try upsert(entry)
            return entry
        } ?? nil
    }

    func list(_ query: AskWordBookQuery) -> [AskWordBookEntry] {
        read("list") {
            let (condition, filters) = Self.conditions(query)
            var values = filters
            let order = switch query.sort {
            case .recent: "last_looked_up_at DESC"
            case .count: "lookup_count DESC, last_looked_up_at DESC"
            case .alphabetical: "headword COLLATE NOCASE ASC"
            case .starred: "starred_at IS NULL, starred_at DESC, last_looked_up_at DESC"
            }
            values += [.integer(Int64(max(0, query.limit))), .integer(Int64(max(0, query.offset)))]
            return try fetch(where: condition, values, suffix: "ORDER BY \(order) LIMIT ? OFFSET ?")
        } ?? []
    }

    func count(matching query: AskWordBookQuery) -> Int {
        read("count") {
            let (condition, values) = Self.conditions(query)
            return try integer("SELECT COUNT(*) FROM word_book_entries WHERE \(condition)", values)
        } ?? 0
    }

    func activity(since date: Date) -> [Date] {
        read("activity") {
            var dates: [Date] = []
            try query("SELECT first_looked_up_at, last_looked_up_at FROM word_book_entries WHERE last_looked_up_at >= ?",
                      [.double(date.timeIntervalSince1970)]) { statement in
                dates.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
                dates.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
            }
            return dates.filter { $0 >= date }
        } ?? []
    }

    /// The WHERE clause and its values for a query's filters.
    private static func conditions(_ query: AskWordBookQuery) -> (String, [Value]) {
        var conditions: [String] = []
        var values: [Value] = []
        if query.scope == .starred { conditions.append("starred_at IS NOT NULL") }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            conditions.append("(headword LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\')")
            let pattern = "%" + Self.escapeLike(text) + "%"
            values += [.text(pattern), .text(pattern)]
        }
        if let pair = query.pair {
            if let source = pair.source {
                conditions.append("source_language = ?")
                values.append(.text(source))
            } else {
                conditions.append("source_language IS NULL")
            }
            conditions.append("target_language = ?")
            values.append(.text(pair.target))
        }
        if let since = query.since {
            conditions.append("last_looked_up_at >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values)
    }

    func count(_ scope: AskWordBookQuery.Scope) -> Int {
        read("count") {
            try integer("SELECT COUNT(*) FROM word_book_entries" + (scope == .starred ? " WHERE starred_at IS NOT NULL" : ""))
        } ?? 0
    }

    func lookups(since date: Date) -> Int {
        read("lookups") {
            try integer("SELECT COUNT(*) FROM word_book_entries WHERE last_looked_up_at >= ?",
                        [.double(date.timeIntervalSince1970)])
        } ?? 0
    }

    func languagePairs() -> [AskWordBookLanguagePair] {
        read("pairs") {
            var pairs: [AskWordBookLanguagePair] = []
            try query("""
            SELECT source_language, target_language FROM word_book_entries
            GROUP BY source_language, target_language ORDER BY COUNT(*) DESC
            """, []) { statement in
                guard let target = Self.text(statement, 1) else { return }
                pairs.append(AskWordBookLanguagePair(source: Self.text(statement, 0), target: target))
            }
            return pairs
        } ?? []
    }

    func delete(keys: [String]) {
        guard !keys.isEmpty else { return }
        write("delete") {
            for key in keys { try run("DELETE FROM word_book_entries WHERE lookup_key = ?", [.text(key)]) }
        }
    }

    func restore(_ entries: [AskWordBookEntry]) {
        guard !entries.isEmpty else { return }
        write("restore") { for entry in entries { try upsert(entry) } }
    }

    func purgeHistory(before date: Date?) {
        write("purge") {
            if let date {
                try run("DELETE FROM word_book_entries WHERE starred_at IS NULL AND last_looked_up_at < ?",
                        [.double(date.timeIntervalSince1970)])
            } else {
                try run("DELETE FROM word_book_entries WHERE starred_at IS NULL", [])
            }
        }
    }

    // MARK: - Merging

    /// A new card replaces the old one; a plain translation never replaces a card.
    static func merge(_ lookup: AskWordBookLookup, into entry: inout AskWordBookEntry) {
        var merged = entry.lookup
        if let card = lookup.card {
            // The headword stays as first typed: it is part of the key.
            merged.card = card
            merged.model = lookup.model ?? merged.model
        } else if merged.card == nil, let translation = lookup.translation {
            merged.translation = translation
            merged.model = lookup.model ?? merged.model
        }
        if merged.source == nil { merged.source = lookup.source }
        entry.lookup = merged
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - SQLite

    private enum StoreError: LocalizedError {
        case sqlite(String)
        var errorDescription: String? { if case let .sqlite(message) = self { message } else { nil } }
    }

    private enum Value {
        case text(String?)
        case double(Double?)
        case integer(Int64)
        case blob(Data?)
    }

    private static let columns = """
    id, lookup_key, headword, source_language, target_language, card_json, translation, summary, model,
    lookup_count, first_looked_up_at, last_looked_up_at, starred_at
    """

    private var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func read<T>(_ what: String, _ body: () throws -> T) -> T? {
        queue.sync {
            do { return try body() } catch {
                ErrorLogStore.shared.log("Word book \(what) failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    @discardableResult
    private func write<T>(_ what: String, _ body: () throws -> T) -> T? {
        let result: T? = queue.sync {
            do { return try body() } catch {
                ErrorLogStore.shared.log("Word book \(what) failed: \(error.localizedDescription)")
                return nil
            }
        }
        let center = notificationCenter
        DispatchQueue.main.async { center.post(name: .askWordBookDidChange, object: nil) }
        return result
    }

    private func upsert(_ entry: AskWordBookEntry) throws {
        let card = try entry.lookup.card.map { try JSONEncoder().encode($0) }
        try run("""
        INSERT INTO word_book_entries (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(lookup_key) DO UPDATE SET
            headword = excluded.headword, source_language = excluded.source_language,
            card_json = excluded.card_json, translation = excluded.translation, summary = excluded.summary,
            model = excluded.model, lookup_count = excluded.lookup_count,
            first_looked_up_at = excluded.first_looked_up_at, last_looked_up_at = excluded.last_looked_up_at,
            starred_at = excluded.starred_at
        """, [
            .text(entry.id.uuidString), .text(entry.key), .text(entry.lookup.headword), .text(entry.lookup.source),
            .text(entry.lookup.target), .blob(card), .text(entry.lookup.translation), .text(entry.lookup.summary),
            .text(entry.lookup.model), .integer(Int64(entry.lookupCount)),
            .double(entry.firstLookedUpAt.timeIntervalSince1970), .double(entry.lastLookedUpAt.timeIntervalSince1970),
            .double(entry.starredAt?.timeIntervalSince1970)
        ])
    }

    private func fetch(where condition: String, _ values: [Value], suffix: String = "") throws -> [AskWordBookEntry] {
        var entries: [AskWordBookEntry] = []
        try query("SELECT \(Self.columns) FROM word_book_entries WHERE \(condition) \(suffix)", values) { statement in
            guard let id = Self.text(statement, 0).flatMap(UUID.init(uuidString:)),
                  let headword = Self.text(statement, 2), let target = Self.text(statement, 4) else { return }
            let card = Self.blob(statement, 5).flatMap { try? JSONDecoder().decode(AskWordCard.self, from: $0) }
            let lookup = AskWordBookLookup(headword: headword, source: Self.text(statement, 3), target: target,
                                           card: card, translation: Self.text(statement, 6),
                                           model: Self.text(statement, 8))
            entries.append(AskWordBookEntry(
                id: id, lookup: lookup, lookupCount: Int(sqlite3_column_int64(statement, 9)),
                firstLookedUpAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                lastLookedUpAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                starredAt: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            ))
        }
        return entries
    }

    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int {
        var result = 0
        try query(sql, values) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(message) }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        try query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(message)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text):
                if let text { sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(statement, index) }
            case let .double(number):
                if let number { sqlite3_bind_double(statement, index, number) } else { sqlite3_bind_null(statement, index) }
            case let .integer(number):
                sqlite3_bind_int64(statement, index, number)
            case let .blob(data):
                if let data {
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw StoreError.sqlite(message)
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
