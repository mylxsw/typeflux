import Foundation
import SQLite3

/// A separate WAL journal keeps watcher writes off the UI and independent of long index transactions.
/// Overflow is persisted as an affected-root scan, never dropped or expanded into an in-memory backlog.
final class SemanticIndexEvents: @unchecked Sendable {
    struct Entry {
        var path: String
        var subtree: Bool
        var revision: Int64
        var root: String
    }

    static let batchSize = 128
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var notificationPending = false
    private var lastSeenEventID: UInt64 = 0
    private var hasStoredReceipt = false

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            sqlite3_close(database); throw SemanticFileStore.Failure.database
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(database, 1000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS clock(value INTEGER NOT NULL)")
            try execute("INSERT INTO clock SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM clock)")
            try execute("""
            CREATE TABLE IF NOT EXISTS events(path TEXT PRIMARY KEY,root TEXT NOT NULL,subtree INTEGER NOT NULL,revision INTEGER NOT NULL)
            """)
            try execute("CREATE INDEX IF NOT EXISTS event_roots ON events(root)")
            try execute("CREATE TABLE IF NOT EXISTS coalescing(value INTEGER NOT NULL)")
            try execute("INSERT INTO coalescing SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM coalescing)")
            try execute("CREATE TABLE IF NOT EXISTS watch_cursor(value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS watch_scope(scope TEXT NOT NULL,volume_signature TEXT NOT NULL)")
            try execute("INSERT INTO watch_cursor SELECT ? WHERE NOT EXISTS(SELECT 1 FROM watch_cursor)",
                        [String(AskFSEventsWatcher.currentEventID)])
            hasStoredReceipt = sqlite3_changes(database) == 0
            let row = try prepare("SELECT value FROM watch_cursor", [])
            defer { sqlite3_finalize(row) }
            if sqlite3_step(row) == SQLITE_ROW {
                lastSeenEventID = UInt64(String(cString: sqlite3_column_text(row, 0))) ?? 0
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    func close() {
        lock.withLock {
            try? saveEventID()
            sqlite3_close(database); database = nil
        }
    }

    var eventID: UInt64 {
        lock.withLock { lastSeenEventID }
    }

    /// The receipt is safe to replay from before extraction finishes: every relevant
    /// event preceding it is already in this journal or the main index's durable queue.
    /// Never reuse a receipt from another scope, volume history, or an unbound legacy journal.
    func resume(scope: AskFileScope, volumeSignature: String?, after completed: UInt64?, latest: UInt64) throws -> UInt64 {
        let key = try SemanticFileStore.discoveryKey(scope)
        let baseline = completed.flatMap { $0 <= latest ? $0 : nil } ?? latest
        return try lock.withLock {
            let row = try prepare("SELECT scope,volume_signature FROM watch_scope", [])
            let matches = sqlite3_step(row) == SQLITE_ROW && volumeSignature != nil
                && String(cString: sqlite3_column_text(row, 0)) == key
                && String(cString: sqlite3_column_text(row, 1)) == volumeSignature
            sqlite3_finalize(row)
            let minimum = completed.flatMap { $0 <= latest ? $0 : nil } ?? 0
            if matches, lastSeenEventID >= minimum, lastSeenEventID <= latest {
                return lastSeenEventID
            }
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM events")
                // Legacy or incompatible receipts have no trustworthy provenance.
                // Persist bounded root catch-up instead of replaying months of raw
                // filesystem history. An interrupted first scan also needs catch-up
                // for changes below directories it has already visited.
                if baseline < latest || (completed == nil && hasStoredReceipt) {
                    try execute("UPDATE clock SET value=value+1")
                    for root in scope.roots { try insert(root, subtree: true, scope: scope) }
                }
                try execute("DELETE FROM watch_scope")
                try execute("INSERT INTO watch_scope VALUES(?,?)", [key, volumeSignature ?? ""])
                try execute("UPDATE watch_cursor SET value=?", [String(latest)])
                try execute("COMMIT")
                lastSeenEventID = latest
                hasStoredReceipt = true
                return latest
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private func saveEventID() throws {
        let value = String(lastSeenEventID)
        try execute("""
        UPDATE watch_cursor SET value=? WHERE length(value)<length(?) OR (length(value)=length(?) AND value<?)
        """, [value, value, value, value])
    }

    /// Called synchronously on the watcher queue, before scheduling a single coalesced UI notification.
    @discardableResult
    func append(_ changes: [AskFileChange], scope: AskFileScope, directory: String,
                eventID: UInt64? = nil, cancelled: () -> Bool) throws -> Bool {
        guard !cancelled() else { throw CancellationError() }
        var changed = false
        for start in stride(from: 0, to: changes.count, by: Self.batchSize) {
            var plan = SemanticFileChangePlan.make(Array(changes[start ..< min(start + Self.batchSize, changes.count)]),
                                                   scope: scope, indexDirectory: directory)
            if plan.fullScan { plan.subtrees = Set(scope.roots) }
            guard !plan.files.isEmpty || !plan.subtrees.isEmpty else { continue }
            try lock.withLock {
                guard let database else { throw SemanticFileStore.Failure.database }
                try SemanticSQLiteCancellation.read(database, cancelled: cancelled) {
                    try execute("BEGIN IMMEDIATE")
                    do {
                        try execute("UPDATE clock SET value=value+1")
                        for path in plan.subtrees.sorted() {
                            try insert(path, subtree: true, scope: scope)
                        }
                        for path in plan.files.sorted() {
                            try insert(path, subtree: false, scope: scope)
                        }
                        try execute("COMMIT")
                    } catch { try? execute("ROLLBACK"); throw error }
                }
            }
            changed = true
        }
        // Ignored artifact events must not write another cursor update and create an event loop.
        // On a clean stop the watcher is stopped before close() persists the final ignored cursor.
        try lock.withLock {
            guard !cancelled() else { throw CancellationError() }
            if let eventID {
                lastSeenEventID = max(lastSeenEventID, eventID)
            }
            if changed {
                try saveEventID()
            }
        }
        return changed
    }

    private func insert(_ path: String, subtree: Bool, scope: AskFileScope) throws {
        guard let root = scope.roots.filter({ AskFileScope.isInside(path, $0) }).max(by: { $0.count < $1.count })
        else { return }
        let parents = try rows("SELECT path,subtree,revision,root FROM events WHERE root=? AND subtree=1", [root])
        if let parent = parents.first(where: { AskFileScope.isInside(path, $0.path) }) {
            try execute("UPDATE events SET revision=(SELECT value FROM clock) WHERE path=?", [parent.path])
            return
        }
        if subtree {
            try execute("DELETE FROM events WHERE root=? AND (path=? OR substr(path,1,length(?)+1)=?||'/')",
                        [root, path, path, path])
        }
        try execute(
            "INSERT OR REPLACE INTO events VALUES(?,?,?,(SELECT value FROM clock))",
            [path, root, subtree ? 1 : 0]
        )
        let pending = try rows("SELECT path,subtree,revision,root FROM events WHERE root=? LIMIT 129", [root])
        if pending.count > Self.batchSize {
            try execute("DELETE FROM events WHERE root=?", [root])
            try execute("INSERT INTO events VALUES(?,?,1,(SELECT value FROM clock))", [root, root])
            try execute("UPDATE coalescing SET value=value+1")
        }
    }

    func queueStatistics() throws -> (entries: Int, coalesced: Int) {
        try lock.withLock {
            let row = try prepare("SELECT (SELECT count(*) FROM events),value FROM coalescing", [])
            defer { sqlite3_finalize(row) }
            guard sqlite3_step(row) == SQLITE_ROW else { throw SemanticFileStore.Failure.database }
            return (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)))
        }
    }

    func requestNotification() -> Bool {
        lock.withLock {
            guard !notificationPending else { return false }
            notificationPending = true; return true
        }
    }

    func receivedNotification() {
        lock.withLock { notificationPending = false }
    }

    func pending() throws -> Bool {
        try lock.withLock { try !rows("SELECT path,subtree,revision,root FROM events LIMIT 1").isEmpty }
    }

    /// Acknowledge only after the main index has committed its durable queue. Revision guards retain
    /// another event for the same path received during transfer; crash replay is idempotent.
    func transfer(to store: SemanticFileStore, cancelled: () -> Bool = { false }) throws {
        guard !cancelled() else { throw CancellationError() }
        let batch = try lock
            .withLock { try rows("SELECT path,subtree,revision,root FROM events ORDER BY revision,path LIMIT 128") }
        guard !batch.isEmpty else { return }
        try store.acceptEvents(batch, cancelled: cancelled)
        try lock.withLock {
            guard !cancelled() else { throw CancellationError() }
            try execute("BEGIN IMMEDIATE")
            do {
                for entry in batch {
                    try execute(
                        "DELETE FROM events WHERE path=? AND revision=?",
                        [entry.path, entry.revision]
                    )
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private func prepare(_ sql: String, _ values: [Any]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw SemanticFileStore.Failure.database }
        for (index, value) in values.enumerated() {
            if let string = value as? String {
                sqlite3_bind_text(
                    statement,
                    Int32(index + 1),
                    string,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            } else if let number = value as? Int64 {
                sqlite3_bind_int64(statement, Int32(index + 1), number)
            } else if let number = value as? Int {
                sqlite3_bind_int64(statement, Int32(index + 1), Int64(number))
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [Any] = []) throws {
        let row = try prepare(sql, values)
        defer { sqlite3_finalize(row) }
        let result = sqlite3_step(row)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw SemanticFileStore.Failure.database }
    }

    private func rows(_ sql: String, _ values: [Any] = []) throws -> [Entry] {
        let row = try prepare(sql, values)
        defer { sqlite3_finalize(row) }
        var entries: [Entry] = [], step = sqlite3_step(row)
        while step == SQLITE_ROW {
            entries.append(.init(path: String(cString: sqlite3_column_text(row, 0)),
                                 subtree: sqlite3_column_int(row, 1) != 0, revision: sqlite3_column_int64(row, 2),
                                 root: String(cString: sqlite3_column_text(row, 3))))
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw SemanticFileStore.Failure.database }
        return entries
    }
}
