import Foundation
import SQLite3

/// Where a conversation is kept. Cloud conversations are owned by Typeflux and
/// cached here; local ones exist only on this device.
public enum ChatStorage: String, Codable, Sendable {
    case cloud
    case local
}

public struct ChatStoredSummary: Equatable, Sendable {
    public var summary: ChatConversationSummary
    public var storage: ChatStorage
    public var modelRef: String?
    /// False when only the title is kept (older cloud conversations).
    public var hasContent: Bool
}

public struct ChatDraft: Codable, Equatable, Sendable {
    public var text: String
    public var image: String?

    public init(text: String, image: String? = nil) {
        self.text = text; self.image = image
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil }
}

public struct ChatCachedValue<Value: Sendable>: Sendable {
    public var value: Value
    public var savedAt: Date
}

public enum ChatLocalStoreError: Error, Equatable {
    case open(String)
    case statement(String)
}

/// A small SQLite store for conversations, drafts and cached values, partitioned
/// by owner (an account, or `local` for device-only data). Actor isolation
/// serializes access to the single connection.
public actor ChatLocalStore {
    private var db: OpaquePointer?
    private let encoder = ChatCoding.encoder()
    private let decoder = ChatCoding.decoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    /// A store that never touches the disk.
    public static func inMemory() throws -> ChatLocalStore { try ChatLocalStore(path: ":memory:") }

    private init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ChatLocalStoreError.open(path)
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA busy_timeout=3000;
        CREATE TABLE IF NOT EXISTS conversations(owner TEXT NOT NULL, id TEXT NOT NULL, storage TEXT NOT NULL,
            title TEXT NOT NULL, updated_at REAL NOT NULL, revision INTEGER NOT NULL DEFAULT 0, model_ref TEXT,
            data BLOB, PRIMARY KEY(owner, id));
        CREATE INDEX IF NOT EXISTS conversations_recent ON conversations(owner, updated_at DESC);
        CREATE TABLE IF NOT EXISTS drafts(owner TEXT NOT NULL, id TEXT NOT NULL, data BLOB NOT NULL,
            PRIMARY KEY(owner, id));
        CREATE TABLE IF NOT EXISTS kv(owner TEXT NOT NULL, key TEXT NOT NULL, data BLOB NOT NULL,
            saved_at REAL NOT NULL, PRIMARY KEY(owner, key));
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw ChatLocalStoreError.open(message)
        }
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Conversations

    /// Upserts one page of the server's history. The first page also removes
    /// cached cloud conversations it should have contained but did not: they were
    /// deleted on another device. `complete` means the page holds the whole history.
    public func syncCloudPage(_ items: [ChatConversationSummary], owner: String, firstPage: Bool,
                              complete: Bool) throws {
        try transaction {
            for item in items {
                try run("""
                INSERT INTO conversations(owner, id, storage, title, updated_at) VALUES(?, ?, 'cloud', ?, ?)
                ON CONFLICT(owner, id) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at
                WHERE storage = 'cloud'
                """, [.text(owner), .text(item.id), .text(item.title), .real(item.updatedAt.timeIntervalSince1970)])
            }
            guard firstPage else { return }
            let ids = Set(items.map(\.id))
            let oldest = complete ? -Double.infinity : items.map(\.updatedAt.timeIntervalSince1970).min() ?? .infinity
            let cached = try query("SELECT id, updated_at FROM conversations WHERE owner = ? AND storage = 'cloud'",
                                   [.text(owner)]) { ($0.text(0), $0.real(1)) }
            for (id, updated) in cached where !ids.contains(id) && updated >= oldest {
                try run("DELETE FROM conversations WHERE owner = ? AND id = ?", [.text(owner), .text(id)])
            }
        }
    }

    /// Saves a conversation's content. Cloud copies only move forward by revision,
    /// so a late snapshot never replaces a newer one.
    public func save(_ conversation: ChatConversation, storage: ChatStorage, owner: String,
                     modelRef: String? = nil) throws {
        let data = try encoder.encode(conversation)
        try run("""
        INSERT INTO conversations(owner, id, storage, title, updated_at, revision, model_ref, data)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner, id) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at,
            revision = excluded.revision, model_ref = COALESCE(excluded.model_ref, conversations.model_ref),
            data = excluded.data
        WHERE conversations.storage = excluded.storage
            AND (excluded.storage = 'local' OR conversations.data IS NULL
                 OR excluded.revision >= conversations.revision)
        """, [.text(owner), .text(conversation.id), .text(storage.rawValue), .text(conversation.title),
              .real(conversation.updatedAt.timeIntervalSince1970), .int(conversation.revision),
              modelRef.map(Value.text) ?? .null, .blob(data)])
    }

    public func conversation(id: String, owner: String) throws -> ChatConversation? {
        let rows = try query("SELECT data FROM conversations WHERE owner = ? AND id = ? AND data IS NOT NULL",
                             [.text(owner), .text(id)]) { $0.blob(0) }
        guard let data = rows.first ?? nil else { return nil }
        return try? decoder.decode(ChatConversation.self, from: data)
    }

    public func summaries(owner: String) throws -> [ChatStoredSummary] {
        try query("""
        SELECT id, title, updated_at, storage, model_ref, data IS NOT NULL FROM conversations
        WHERE owner = ? ORDER BY updated_at DESC
        """, [.text(owner)]) { row in
            ChatStoredSummary(
                summary: ChatConversationSummary(id: row.text(0), title: row.text(1),
                                                 updatedAt: Date(timeIntervalSince1970: row.real(2))),
                storage: ChatStorage(rawValue: row.text(3)) ?? .cloud,
                modelRef: row.optionalText(4),
                hasContent: row.int(5) != 0
            )
        }
    }

    public func modelRef(id: String, owner: String) throws -> String? {
        try query("SELECT model_ref FROM conversations WHERE owner = ? AND id = ?", [.text(owner), .text(id)]) {
            $0.optionalText(0)
        }.first ?? nil
    }

    /// Remembers the model last used in a conversation that is already stored.
    public func setModelRef(_ reference: String, id: String, owner: String) throws {
        try run("UPDATE conversations SET model_ref = ? WHERE owner = ? AND id = ?",
                [.text(reference), .text(owner), .text(id)])
    }

    public func delete(id: String, owner: String) throws {
        try transaction {
            try run("DELETE FROM conversations WHERE owner = ? AND id = ?", [.text(owner), .text(id)])
            try run("DELETE FROM drafts WHERE owner = ? AND id = ?", [.text(owner), .text(id)])
        }
    }

    /// Removes everything kept for an owner: conversations, drafts and cached values.
    public func deleteAll(owner: String) throws {
        try transaction {
            for table in ["conversations", "drafts", "kv"] {
                try run("DELETE FROM \(table) WHERE owner = ?", [.text(owner)])
            }
        }
    }

    /// Keeps the full content of the most recent `keep` cloud conversations; older
    /// ones keep only their title until opened again.
    public func prune(owner: String, keep: Int) throws {
        try run("""
        UPDATE conversations SET data = NULL, revision = 0 WHERE owner = ? AND storage = 'cloud' AND data IS NOT NULL
        AND id NOT IN (SELECT id FROM conversations WHERE owner = ? AND storage = 'cloud' AND data IS NOT NULL
                       ORDER BY updated_at DESC LIMIT ?)
        """, [.text(owner), .text(owner), .int(Int64(max(0, keep)))])
    }

    /// Bytes of conversation content kept for an owner.
    public func contentSize(owner: String) throws -> Int {
        Int(try query("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM conversations WHERE owner = ?",
                      [.text(owner)]) { $0.int(0) }.first ?? 0)
    }

    // MARK: Drafts

    /// Saves a conversation's unsent draft; an empty draft removes it.
    public func saveDraft(_ draft: ChatDraft?, id: String, owner: String) throws {
        guard let draft, !draft.isEmpty else {
            try run("DELETE FROM drafts WHERE owner = ? AND id = ?", [.text(owner), .text(id)])
            return
        }
        try run("INSERT OR REPLACE INTO drafts(owner, id, data) VALUES(?, ?, ?)",
                [.text(owner), .text(id), .blob(try encoder.encode(draft))])
    }

    public func draft(id: String, owner: String) throws -> ChatDraft? {
        let rows = try query("SELECT data FROM drafts WHERE owner = ? AND id = ?", [.text(owner), .text(id)]) {
            $0.blob(0)
        }
        guard let data = rows.first ?? nil else { return nil }
        return try? decoder.decode(ChatDraft.self, from: data)
    }

    // MARK: Cached values

    public func saveValue(_ value: some Encodable, key: String, owner: String, at date: Date = Date()) throws {
        try run("INSERT OR REPLACE INTO kv(owner, key, data, saved_at) VALUES(?, ?, ?, ?)",
                [.text(owner), .text(key), .blob(try encoder.encode(value)), .real(date.timeIntervalSince1970)])
    }

    public func value<Value: Decodable & Sendable>(_: Value.Type, key: String,
                                                   owner: String) throws -> ChatCachedValue<Value>? {
        let rows = try query("SELECT data, saved_at FROM kv WHERE owner = ? AND key = ?",
                             [.text(owner), .text(key)]) { ($0.blob(0), $0.real(1)) }
        guard let (data, saved) = rows.first, let data,
              let value = try? decoder.decode(Value.self, from: data) else { return nil }
        return ChatCachedValue(value: value, savedAt: Date(timeIntervalSince1970: saved))
    }

    public func deleteValue(key: String, owner: String) throws {
        try run("DELETE FROM kv WHERE owner = ? AND key = ?", [.text(owner), .text(key)])
    }

    // MARK: SQLite

    private enum Value {
        case text(String)
        case real(Double)
        case int(Int64)
        case blob(Data)
        case null
    }

    private struct Row {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }

        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }

        func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

        func blob(_ index: Int32) -> Data? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatLocalStoreError.statement(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .real(number): sqlite3_bind_double(statement, index, number)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .blob(data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ChatLocalStoreError.statement(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<Result>(_ sql: String, _ values: [Value], map: (Row) -> Result) throws -> [Result] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [Result] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw ChatLocalStoreError.statement(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}
