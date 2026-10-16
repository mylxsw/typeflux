import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// The notes in `notes.sqlite`, next to the history database. Search uses LIKE rather
// than FTS5: SQLite's tokenizers do not split Chinese or Japanese into words, and a
// personal notebook stays small enough to scan.
// Keep schema, transactions and connection access together under one private serial queue.
// swiftlint:disable:next type_body_length
final class SQLiteAskNoteStore: AskNoteStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ask.notes.sqlite")
    private var db: OpaquePointer?
    /// Where change notifications go; tests count them.
    var notificationCenter: NotificationCenter = .default

    init(url: URL, busyTimeoutMilliseconds: Int32 = 250) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure }
            sqlite3_busy_timeout(db, max(0, busyTimeoutMilliseconds))
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try execute("BEGIN IMMEDIATE;")
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
            try migrate()
            try execute("""
            CREATE TABLE IF NOT EXISTS note_revisions (
                note_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_note_revisions ON note_revisions(note_id, created_at DESC);")
            try execute("COMMIT;")
        } catch {
            ErrorLogStore.shared.log("Notes database initialization failed")
            try? execute("ROLLBACK;")
            if let connection = db { sqlite3_close(connection) }
            db = nil
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

    /// Columns added after the first release (GUL-322). Notes saved before keep their
    /// defaults; screenshot text, told apart then only by its command name, is marked as such.
    private func migrate() throws {
        var existing = Set<String>()
        try query("PRAGMA table_info(notes)", []) { statement in
            if let name = Self.text(statement, 1) { existing.insert(name) }
        }
        let added: [(String, String)] = [
            ("source_kind", "TEXT NOT NULL DEFAULT 'command'"), ("conversation_id", "TEXT"), ("message_id", "TEXT"),
            ("original_body", "TEXT"), ("deleted_at", "REAL"), ("author", "TEXT NOT NULL DEFAULT 'user'")
        ]
        for (column, type) in added where !existing.contains(column) {
            try execute("ALTER TABLE notes ADD COLUMN \(column) \(type);")
            if column == "source_kind" {
                let titles = Self.screenshotCommandNames
                let marks = titles.map { _ in "?" }.joined(separator: ", ")
                try run("UPDATE notes SET source_kind = 'screenshot' WHERE command IN (\(marks))", titles.map { .text($0) })
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_notes_deleted ON notes(deleted_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_notes_conversation ON notes(conversation_id);")
    }

    /// "Screenshot to Text" in every language the app ships.
    static var screenshotCommandNames: [String] {
        var names: Set<String> = [L("screenshot.text.title")]
        for language in AppLanguage.allCases {
            names.insert(AppLocalization.shared.string("screenshot.text.title", in: language))
        }
        return names.sorted()
    }

    // MARK: - AskNoteStoring

    func note(id: UUID) throws -> AskNote? {
        try read("note") { () throws -> AskNote? in try fetch(where: "id = ?", [.text(id.uuidString)]).first }
    }

    @discardableResult
    func save(_ note: AskNote) throws -> Bool {
        try write("save") { try upsert(note); return true }
    }

    @discardableResult
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) throws -> Bool {
        try write("replace") {
            let stored = try fetch(where: "id = ?", [.text(previous.id.uuidString)]).first
            guard note.id == previous.id, stored == Self.persistedSnapshot(previous) else {
                return false
            }
            if let date { try insertRevision(previous, at: date) }
            try upsert(note)
            return true
        }
    }

    /// SQLite stores Unix timestamps; converting Date's reference epoch can round a
    /// submicrosecond away. Compare the same representation without weakening text checks.
    private static func persistedSnapshot(_ note: AskNote) -> AskNote {
        var snapshot = note
        snapshot.createdAt = Date(timeIntervalSince1970: note.createdAt.timeIntervalSince1970)
        snapshot.updatedAt = Date(timeIntervalSince1970: note.updatedAt.timeIntervalSince1970)
        snapshot.editedAt = note.editedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970) }
        snapshot.deletedAt = note.deletedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970) }
        return snapshot
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try write("delete") {
            for id in ids {
                try run("DELETE FROM note_revisions WHERE note_id = ?", [.text(id.uuidString)])
                try run("DELETE FROM notes WHERE id = ?", [.text(id.uuidString)])
            }
        }
    }

    func restore(_ notes: [AskNote]) throws {
        guard !notes.isEmpty else { return }
        try write("restore") { for note in notes { try upsert(note) } }
    }

    func list(_ query: AskNoteQuery) throws -> [AskNote] {
        try read("list") {
            let (condition, filters) = Self.conditions(query)
            let order = switch query.sort {
            case .created: "created_at DESC"
            case .updated: "updated_at DESC"
            case .title: "title COLLATE NOCASE ASC, updated_at DESC"
            }
            // Recently Deleted lists what went last first, pins aside.
            let pins = query.scope == .trash ? "deleted_at DESC" : "pinned DESC"
            let values = filters + [.integer(Int64(max(0, query.limit))), .integer(Int64(max(0, query.offset)))]
            return try fetch(where: condition, values, suffix: "ORDER BY \(pins), \(order) LIMIT ? OFFSET ?")
        }
    }

    func count(_ scope: AskNoteQuery.Scope) throws -> Int {
        try read("count") {
            let (condition, values) = Self.conditions(AskNoteQuery(scope: scope))
            return try integer("SELECT COUNT(*) FROM notes WHERE \(condition)", values)
        }
    }

    func commands() throws -> [AskNoteFacet] {
        try facets("commands", """
        SELECT command, COUNT(*) FROM notes WHERE deleted_at IS NULL AND source_kind = 'command' AND command != ''
        GROUP BY command ORDER BY COUNT(*) DESC, command COLLATE NOCASE ASC
        """)
    }

    func sources() throws -> [AskNoteFacet] {
        try facets("sources", """
        SELECT source_kind, COUNT(*) FROM notes WHERE deleted_at IS NULL GROUP BY source_kind
        """)
    }

    func tags() throws -> [AskNoteFacet] {
        try facets("tags", """
        SELECT tag.value, COUNT(*) FROM notes, json_each(notes.tags_json) AS tag WHERE notes.deleted_at IS NULL
        GROUP BY tag.value ORDER BY COUNT(*) DESC, tag.value COLLATE NOCASE ASC
        """)
    }

    func trash(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else { return }
        try write("trash") {
            for id in ids {
                try run("UPDATE notes SET deleted_at = ? WHERE id = ?",
                        [.double(date.timeIntervalSince1970), .text(id.uuidString)])
            }
        }
    }

    func purgeTrash(before date: Date) throws {
        try write("purge") {
            let cutoff = Value.double(date.timeIntervalSince1970)
            try run("DELETE FROM note_revisions WHERE note_id IN (SELECT id FROM notes WHERE deleted_at < ?)", [cutoff])
            try run("DELETE FROM notes WHERE deleted_at < ?", [cutoff])
        }
    }

    func saveRevision(_ note: AskNote, at date: Date) throws {
        try write("revision") { try insertRevision(note, at: date) }
    }

    private func insertRevision(_ note: AskNote, at date: Date) throws {
        try run("INSERT INTO note_revisions (note_id, title, body, created_at) VALUES (?, ?, ?, ?)",
                [.text(note.id.uuidString), .text(note.title), .text(note.body), .double(date.timeIntervalSince1970)])
        try run("""
        DELETE FROM note_revisions WHERE note_id = ? AND rowid NOT IN (
            SELECT rowid FROM note_revisions WHERE note_id = ? ORDER BY created_at DESC, rowid DESC LIMIT \(Self.revisionLimit))
        """, [.text(note.id.uuidString), .text(note.id.uuidString)])
    }

    func revisions(of id: UUID) throws -> [AskNoteRevision] {
        try read("revisions") {
            var result: [AskNoteRevision] = []
            try query("""
            SELECT title, body, created_at FROM note_revisions WHERE note_id = ? ORDER BY created_at DESC, rowid DESC
            """,
                      [.text(id.uuidString)]) { statement in
                let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                result.append(AskNoteRevision(noteID: id, title: Self.text(statement, 0) ?? "",
                                              body: Self.text(statement, 1) ?? "",
                                              createdAt: date))
            }
            return result
        }
    }

    func deleteRevision(of id: UUID, at date: Date) throws {
        try write("revision delete") {
            try run("""
            DELETE FROM note_revisions WHERE rowid = (
                SELECT rowid FROM note_revisions WHERE note_id = ? AND created_at = ? ORDER BY rowid DESC LIMIT 1)
            """,
                    [.text(id.uuidString), .double(date.timeIntervalSince1970)])
        }
    }

    static let revisionLimit = 20

    /// The WHERE clause and its values for a query's scope and text.
    private static func conditions(_ query: AskNoteQuery) -> (String, [Value]) {
        var conditions: [String] = [query.scope == .trash ? "deleted_at IS NOT NULL" : "deleted_at IS NULL"]
        var values: [Value] = []
        switch query.scope {
        case .all, .trash: break
        case .pinned: conditions.append("pinned = 1")
        case .recent:
            conditions.append("updated_at >= ?")
            values.append(.double(Date().timeIntervalSince1970 - AskNoteQuery.recentInterval))
        case let .command(name):
            conditions.append("source_kind = 'command' AND command = ?")
            values.append(.text(name))
        case let .source(source):
            conditions.append("source_kind = ?")
            values.append(.text(source.rawValue))
        case let .tag(tag):
            conditions.append("EXISTS (SELECT 1 FROM json_each(notes.tags_json) WHERE json_each.value = ?)")
            values.append(.text(tag))
        }
        if let conversationID = query.conversationID {
            conditions.append("conversation_id = ?")
            values.append(.text(conversationID))
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            conditions.append("(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR input LIKE ? ESCAPE '\\')")
            let pattern = "%" + SQLiteAskWordBookStore.escapeLike(text) + "%"
            values += [.text(pattern), .text(pattern), .text(pattern)]
        }
        return (conditions.joined(separator: " AND "), values)
    }

    // MARK: - SQLite

    private enum Value {
        case text(String?)
        case double(Double?)
        case integer(Int64)
    }

    private static let columns = """
    id, title, body, command, keyword, input, model, source_app, source_bundle_id, tags_json, pinned,
    created_at, updated_at, edited_at, source_kind, conversation_id, message_id, original_body, deleted_at, author
    """

    private var failure: LocalStoreFailure {
        guard let db else { return .unavailable }
        switch sqlite3_errcode(db) {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .invalidData
        default: return .unavailable
        }
    }

    private func read<T>(_ what: String, _ body: () throws -> T) throws -> T {
        try queue.sync { try body() }
    }

    @discardableResult
    private func write<T>(_ what: String, _ body: () throws -> T) throws -> T {
        let result: T = try queue.sync {
            do {
                try execute("BEGIN IMMEDIATE;")
                let result = try body()
                try execute("COMMIT;")
                return result
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
        if (result as? Bool) != false {
            let center = notificationCenter
            DispatchQueue.main.async { center.post(name: .askNotesDidChange, object: nil) }
        }
        return result
    }

    private func facets(_ what: String, _ sql: String) throws -> [AskNoteFacet] {
        try read(what) {
            var facets: [AskNoteFacet] = []
            try query(sql, []) { statement in
                guard let name = Self.text(statement, 0) else { return }
                facets.append(AskNoteFacet(name: name, count: Int(sqlite3_column_int64(statement, 1))))
            }
            return facets
        }
    }

    private func upsert(_ note: AskNote) throws {
        let tags = String(data: try JSONEncoder().encode(note.tags), encoding: .utf8) ?? "[]"
        try run("""
        INSERT INTO notes (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, body = excluded.body, command = excluded.command, keyword = excluded.keyword,
            input = excluded.input, model = excluded.model, source_app = excluded.source_app,
            source_bundle_id = excluded.source_bundle_id, tags_json = excluded.tags_json, pinned = excluded.pinned,
            created_at = excluded.created_at, updated_at = excluded.updated_at, edited_at = excluded.edited_at,
            source_kind = excluded.source_kind, conversation_id = excluded.conversation_id,
            message_id = excluded.message_id, original_body = excluded.original_body,
            deleted_at = excluded.deleted_at, author = excluded.author
        """, [
            .text(note.id.uuidString), .text(note.title), .text(note.body), .text(note.command), .text(note.keyword),
            .text(note.input), .text(note.model), .text(note.sourceApp), .text(note.sourceBundleID), .text(tags),
            .integer(note.pinned ? 1 : 0), .double(note.createdAt.timeIntervalSince1970),
            .double(note.updatedAt.timeIntervalSince1970), .double(note.editedAt?.timeIntervalSince1970),
            .text(note.source.rawValue), .text(note.conversationID), .text(note.messageID), .text(note.originalBody),
            .double(note.deletedAt?.timeIntervalSince1970), .text(note.author.rawValue)
        ])
    }

    private func fetch(where condition: String, _ values: [Value], suffix: String = "") throws -> [AskNote] {
        var notes: [AskNote] = []
        try query("SELECT \(Self.columns) FROM notes WHERE \(condition) \(suffix)", values) { statement in
            guard let id = Self.text(statement, 0).flatMap(UUID.init(uuidString:)) else { throw LocalStoreFailure.invalidData }
            guard let data = Self.text(statement, 9)?.data(using: .utf8),
                  let tags = try? JSONDecoder().decode([String].self, from: data) else {
                throw LocalStoreFailure.invalidData
            }
            notes.append(AskNote(
                id: id, title: Self.text(statement, 1) ?? "", body: Self.text(statement, 2) ?? "",
                command: Self.text(statement, 3) ?? "", keyword: Self.text(statement, 4) ?? "",
                input: Self.text(statement, 5) ?? "", model: Self.text(statement, 6),
                sourceApp: Self.text(statement, 7), sourceBundleID: Self.text(statement, 8), tags: tags,
                pinned: sqlite3_column_int64(statement, 10) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                editedAt: Self.date(statement, 13),
                source: Self.text(statement, 14).flatMap(AskNoteSource.init(rawValue:)) ?? .command,
                conversationID: Self.text(statement, 15), messageID: Self.text(statement, 16),
                originalBody: Self.text(statement, 17), deletedAt: Self.date(statement, 18),
                author: Self.text(statement, 19).flatMap(AskNoteAuthor.init(rawValue:)) ?? .user
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
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        try query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw failure
            }
        }
    }

    private func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) throws {
        let status: Int32
        switch value {
        case let .text(text):
            if let text {
                guard let length = Int32(exactly: text.utf8.count) else { throw LocalStoreFailure.invalidData }
                status = sqlite3_bind_text(statement, index, text, length, SQLITE_TRANSIENT)
            } else {
                status = sqlite3_bind_null(statement, index)
            }
        case let .double(number):
            if let number {
                status = sqlite3_bind_double(statement, index, number)
            } else {
                status = sqlite3_bind_null(statement, index)
            }
        case let .integer(number):
            status = sqlite3_bind_int64(statement, index, number)
        }
        guard status == SQLITE_OK else { throw failure }
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        // Repair invalid stored UTF-8 while preserving the rest of the note, including embedded NULs.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}
