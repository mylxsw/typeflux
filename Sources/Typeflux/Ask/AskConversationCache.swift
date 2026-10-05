import Foundation
import SQLite3

protocol AskCaching: Sendable {
    func execution(id: String, owner: String) async throws -> AskExecutionEntry?
    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry]
    func claimExecution(_ audit: AskExecutionAudit, owner: String) async throws -> Bool
    func saveRejectedToolReceipt(audit: AskExecutionAudit, receipt: AskToolResultRequest, owner: String) async throws
    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) async throws
    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) async throws
    func save(_ conversation: AskConversation, owner: String) async throws
    func load(id: String, owner: String) async throws -> AskConversation?
    func list(owner: String) async throws -> [AskConversationSummary]
    func delete(id: String, owner: String) async throws
    func saveDraft(_ draft: AskDraft, key: String, owner: String) async throws
    func draft(key: String, owner: String) async throws -> AskDraft?
    func associateTool(id: String, conversationId: String, owner: String) async throws
    func claimTool(id: String, owner: String) async throws -> Bool
    func saveToolResult(_ result: AskToolResultRequest, owner: String) async throws
    func toolResult(id: String, owner: String) async throws -> AskToolResultRequest?
}

/// Actor isolation serializes access to this connection, including the local
/// execution journal. A claimed tool is never automatically executed twice.
actor AskConversationCache: AskCaching {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CocoaError(.fileWriteUnknown)
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA busy_timeout=3000;
        CREATE TABLE IF NOT EXISTS ask_execution(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(owner,id));
        CREATE TABLE IF NOT EXISTS ask_deleted(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(owner,id));
        CREATE TABLE IF NOT EXISTS ask_cache(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(owner,id));
        CREATE TABLE IF NOT EXISTS ask_drafts(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(owner,id));
        CREATE TABLE IF NOT EXISTS ask_tool_owners(owner TEXT NOT NULL,id TEXT NOT NULL,conversation_id TEXT NOT NULL,PRIMARY KEY(owner,id));
        CREATE TABLE IF NOT EXISTS ask_tools(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB,PRIMARY KEY(owner,id));
        CREATE TRIGGER IF NOT EXISTS ask_keep_tool_journal BEFORE DELETE ON ask_tools
        BEGIN SELECT RAISE(IGNORE); END;
        CREATE TRIGGER IF NOT EXISTS ask_keep_tool_binding BEFORE DELETE ON ask_tool_owners
        BEGIN SELECT RAISE(IGNORE); END;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/ask_conversations.sqlite")
    }

    func save(_ conversation: AskConversation, owner: String) throws {
        guard try read(table: "ask_deleted", id: conversation.id, owner: owner) == nil else {
            throw AskRecoveryError.binding
        }
        let merged = try load(id: conversation.id, owner: owner)?.reconciling(conversation) ?? conversation
        try write(table: "ask_cache", id: conversation.id, owner: owner, data: AskCoding.encoder().encode(merged))
    }
    func load(id: String, owner: String) throws -> AskConversation? {
        try [AskConversationID.canonical(id), AskConversationID.legacy(id)]
            .compactMap { try read(table: "ask_cache", id: $0, owner: owner) }
            .map { try AskCoding.decoder().decode(AskConversation.self, from: $0) }
            .max { $0.revision < $1.revision }
    }
    func list(owner: String) throws -> [AskConversationSummary] {
        let statement = try prepare("SELECT data FROM ask_cache WHERE owner=?", strings: [owner])
        defer { sqlite3_finalize(statement) }
        var snapshots: [String: AskConversation] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let data = blob(statement), let c = try? AskCoding.decoder().decode(AskConversation.self, from: data) {
                if (snapshots[c.id]?.revision ?? -1) <= c.revision { snapshots[c.id] = c }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return snapshots.values.map { AskConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func delete(id: String, owner: String) throws {
        try execute("BEGIN IMMEDIATE", strings: [])
        do {
            // Deletion removes history, never the evidence preventing an unknown effect's replay.
            try write(table: "ask_deleted", id: AskConversationID.canonical(id), owner: owner, data: Data([1]))
            for table in ["ask_cache", "ask_drafts"] {
                let statement = try prepare("DELETE FROM \(table) WHERE owner=? AND id IN (?,?)", strings: [owner, AskConversationID.canonical(id), AskConversationID.legacy(id)])
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
            try execute("COMMIT", strings: [])
        } catch { try? execute("ROLLBACK", strings: []); throw error }
    }
    func associateTool(id: String, conversationId: String, owner: String) throws {
        try execute("INSERT OR IGNORE INTO ask_tool_owners(owner,id,conversation_id) VALUES(?,?,?)", strings: [owner, id, AskConversationID.canonical(conversationId)])
    }
    func execute(_ sql: String, strings: [String]) throws {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
    func saveDraft(_ draft: AskDraft, key: String, owner: String) throws {
        guard try read(table: "ask_deleted", id: AskConversationID.canonical(key), owner: owner) == nil else {
            throw AskRecoveryError.binding
        }
        try write(table: "ask_drafts", id: AskConversationID.canonical(key), owner: owner, data: AskCoding.encoder().encode(draft))
    }
    func draft(key: String, owner: String) throws -> AskDraft? {
        let data = try read(table: "ask_drafts", id: AskConversationID.canonical(key), owner: owner)
            ?? read(table: "ask_drafts", id: AskConversationID.legacy(key), owner: owner)
        return try data.map { try AskCoding.decoder().decode(AskDraft.self, from: $0) }
    }
    func claimTool(id: String, owner: String) throws -> Bool {
        let statement = try prepare("INSERT OR IGNORE INTO ask_tools(owner,id) VALUES(?,?)", strings: [owner, id])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        return sqlite3_changes(db) == 1
    }
    func saveToolResult(_ result: AskToolResultRequest, owner: String) throws {
        try write(table: "ask_tools", id: result.runId + "/" + result.toolCallId, owner: owner, data: AskCoding.encoder().encode(result))
    }
    func toolResult(id: String, owner: String) throws -> AskToolResultRequest? {
        try read(table: "ask_tools", id: id, owner: owner).map { try AskCoding.decoder().decode(AskToolResultRequest.self, from: $0) }
    }

    func prepare(_ sql: String, strings: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CocoaError(.fileReadUnknown) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        return statement
    }
    func write(table: String, id: String, owner: String, data: Data) throws {
        let statement = try prepare("INSERT INTO \(table)(owner,id,data) VALUES(?,?,?) ON CONFLICT(owner,id) DO UPDATE SET data=excluded.data", strings: [owner, id])
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
    func read(table: String, id: String, owner: String) throws -> Data? {
        let statement = try prepare("SELECT data FROM \(table) WHERE owner=? AND id=?", strings: [owner, id])
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return blob(statement)
        case SQLITE_DONE: return nil
        default: throw CocoaError(.fileReadUnknown)
        }
    }
    func blob(_ statement: OpaquePointer) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
