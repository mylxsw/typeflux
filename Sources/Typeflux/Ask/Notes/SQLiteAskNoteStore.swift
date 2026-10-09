import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The notes in `notes.sqlite`, next to the history database. Search uses LIKE rather
/// than FTS5: SQLite's tokenizers do not split Chinese or Japanese into words, and a
/// personal notebook stays small enough to scan.
final class SQLiteAskNoteStore: AskNoteStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ask.notes.sqlite")
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
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                command TEXT NOT NULL,
                keyword TEXT NOT NULL,
                input TEXT NOT NULL,
                model TEXT,
                source_app TEXT,
                source_bundle_id TEXT,
                tags_json TEXT NOT NULL DEFAULT '[]',
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                edited_at REAL
            );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC);")
            try execute("CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at DESC);")
        } catch {
            ErrorLogStore.shared.log("Notes database initialization failed: \(error.localizedDescription)")
        }
    }

    /// `~/Library/Application Support/Typeflux/notes.sqlite`.
    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Typeflux", isDirectory: true).appendingPathComponent("notes.sqlite")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - AskNoteStoring

    func note(id: UUID) -> AskNote? {
        read("note") { () throws -> AskNote? in try fetch(where: "id = ?", [.text(id.uuidString)]).first } ?? nil
    }

    @discardableResult
    func save(_ note: AskNote) -> Bool {
        write("save") { try upsert(note); return true } ?? false
    }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        write("delete") {
            for id in ids { try run("DELETE FROM notes WHERE id = ?", [.text(id.uuidString)]) }
        }
    }

    func restore(_ notes: [AskNote]) {
        guard !notes.isEmpty else { return }
        write("restore") { for note in notes { try upsert(note) } }
    }

    func list(_ query: AskNoteQuery) -> [AskNote] {
        read("list") {
            let (condition, filters) = Self.conditions(query)
            let order = query.sort == .created ? "created_at DESC" : "updated_at DESC"
            let values = filters + [.integer(Int64(max(0, query.limit))), .integer(Int64(max(0, query.offset)))]
            return try fetch(where: condition, values, suffix: "ORDER BY pinned DESC, \(order) LIMIT ? OFFSET ?")
        } ?? []
    }

    func count(_ scope: AskNoteQuery.Scope) -> Int {
        read("count") {
            let (condition, values) = Self.conditions(AskNoteQuery(scope: scope))
            return try integer("SELECT COUNT(*) FROM notes WHERE \(condition)", values)
        } ?? 0
    }

    func commands() -> [AskNoteFacet] {
        facets("commands", """
        SELECT command, COUNT(*) FROM notes GROUP BY command ORDER BY COUNT(*) DESC, command COLLATE NOCASE ASC
        """)
    }

    func tags() -> [AskNoteFacet] {
        facets("tags", """
        SELECT tag.value, COUNT(*) FROM notes, json_each(notes.tags_json) AS tag
        GROUP BY tag.value ORDER BY COUNT(*) DESC, tag.value COLLATE NOCASE ASC
        """)
    }

    /// The WHERE clause and its values for a query's scope and text.
    private static func conditions(_ query: AskNoteQuery) -> (String, [Value]) {
        var conditions: [String] = []
        var values: [Value] = []
        switch query.scope {
        case .all: break
        case .pinned: conditions.append("pinned = 1")
        case let .command(name):
            conditions.append("command = ?")
            values.append(.text(name))
        case let .tag(tag):
            conditions.append("EXISTS (SELECT 1 FROM json_each(notes.tags_json) WHERE json_each.value = ?)")
            values.append(.text(tag))
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            conditions.append("(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR input LIKE ? ESCAPE '\\')")
            let pattern = "%" + SQLiteAskWordBookStore.escapeLike(text) + "%"
            values += [.text(pattern), .text(pattern), .text(pattern)]
        }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values)
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
    }

    private static let columns = """
    id, title, body, command, keyword, input, model, source_app, source_bundle_id, tags_json, pinned,
    created_at, updated_at, edited_at
    """

    private var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func read<T>(_ what: String, _ body: () throws -> T) -> T? {
        queue.sync {
            do { return try body() } catch {
                ErrorLogStore.shared.log("Notes \(what) failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    @discardableResult
    private func write<T>(_ what: String, _ body: () throws -> T) -> T? {
        let result: T? = queue.sync {
            do { return try body() } catch {
                ErrorLogStore.shared.log("Notes \(what) failed: \(error.localizedDescription)")
                return nil
            }
        }
        let center = notificationCenter
        DispatchQueue.main.async { center.post(name: .askNotesDidChange, object: nil) }
        return result
    }

    private func facets(_ what: String, _ sql: String) -> [AskNoteFacet] {
        read(what) {
            var facets: [AskNoteFacet] = []
            try query(sql, []) { statement in
                guard let name = Self.text(statement, 0) else { return }
                facets.append(AskNoteFacet(name: name, count: Int(sqlite3_column_int64(statement, 1))))
            }
            return facets
        } ?? []
    }

    private func upsert(_ note: AskNote) throws {
        let tags = String(data: try JSONEncoder().encode(note.tags), encoding: .utf8) ?? "[]"
        try run("""
        INSERT INTO notes (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, body = excluded.body, command = excluded.command, keyword = excluded.keyword,
            input = excluded.input, model = excluded.model, source_app = excluded.source_app,
            source_bundle_id = excluded.source_bundle_id, tags_json = excluded.tags_json, pinned = excluded.pinned,
            created_at = excluded.created_at, updated_at = excluded.updated_at, edited_at = excluded.edited_at
        """, [
            .text(note.id.uuidString), .text(note.title), .text(note.body), .text(note.command), .text(note.keyword),
            .text(note.input), .text(note.model), .text(note.sourceApp), .text(note.sourceBundleID), .text(tags),
            .integer(note.pinned ? 1 : 0), .double(note.createdAt.timeIntervalSince1970),
            .double(note.updatedAt.timeIntervalSince1970), .double(note.editedAt?.timeIntervalSince1970)
        ])
    }

    private func fetch(where condition: String, _ values: [Value], suffix: String = "") throws -> [AskNote] {
        var notes: [AskNote] = []
        try query("SELECT \(Self.columns) FROM notes WHERE \(condition) \(suffix)", values) { statement in
            guard let id = Self.text(statement, 0).flatMap(UUID.init(uuidString:)) else { return }
            let tags = Self.text(statement, 9).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            notes.append(AskNote(
                id: id, title: Self.text(statement, 1) ?? "", body: Self.text(statement, 2) ?? "",
                command: Self.text(statement, 3) ?? "", keyword: Self.text(statement, 4) ?? "",
                input: Self.text(statement, 5) ?? "", model: Self.text(statement, 6),
                sourceApp: Self.text(statement, 7), sourceBundleID: Self.text(statement, 8), tags: tags,
                pinned: sqlite3_column_int64(statement, 10) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                editedAt: sqlite3_column_type(statement, 13) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
            ))
        }
        return notes
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
                if let text {
                    sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .double(number):
                if let number {
                    sqlite3_bind_double(statement, index, number)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .integer(number):
                sqlite3_bind_int64(statement, index, number)
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
}
