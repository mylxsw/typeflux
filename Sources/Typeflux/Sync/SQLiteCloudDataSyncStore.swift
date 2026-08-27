import Foundation
import SQLite3

private let cloudSyncSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteCloudDataSyncStore {
    struct State {
        var enabled: Bool
        var cursor: Int64
        var checkpoint: Int64
    }

    private let queue = DispatchQueue(label: "typeflux.cloud-data-sync.sqlite")
    private var db: OpaquePointer?
    private(set) var initializationError: Error?
    var isAvailable: Bool { db != nil && initializationError == nil }

    init(baseDirectory: URL? = nil) {
        let directory = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Typeflux", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            initializationError = error
            return
        }
        let url = directory.appendingPathComponent("cloud-sync.sqlite")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            initializationError = databaseError()
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA busy_timeout=5000")
            try execute("""
        CREATE TABLE IF NOT EXISTS sync_accounts(
          user_id TEXT PRIMARY KEY, enabled INTEGER NOT NULL DEFAULT 0,
          cursor INTEGER NOT NULL DEFAULT 0, checkpoint INTEGER NOT NULL DEFAULT 0
        )
        """)
            try execute("""
        CREATE TABLE IF NOT EXISTS sync_entities(
          user_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
          revision INTEGER NOT NULL, payload BLOB NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(user_id,entity_type,entity_id)
        )
        """)
            try execute("""
        CREATE TABLE IF NOT EXISTS sync_outbox(
          user_id TEXT NOT NULL, mutation_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL, operation TEXT NOT NULL, base_revision INTEGER NOT NULL,
          payload BLOB NOT NULL, created_at REAL NOT NULL
        )
        """)
            try execute("CREATE INDEX IF NOT EXISTS sync_outbox_user_created ON sync_outbox(user_id,created_at)")
        } catch {
            initializationError = error
            if let db { sqlite3_close(db) }
            db = nil
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    func state(userID: String) -> State {
        queue.sync {
            var result = State(enabled: false, cursor: 0, checkpoint: 0)
            query("SELECT enabled,cursor,checkpoint FROM sync_accounts WHERE user_id=?", [userID]) { row in
                result = State(enabled: row.int(0) != 0, cursor: row.int64(1), checkpoint: row.int64(2))
            }
            return result
        }
    }

    func hasAccount(userID: String) -> Bool {
        queue.sync {
            var found = false
            query("SELECT 1 FROM sync_accounts WHERE user_id=? LIMIT 1", [userID]) { _ in found = true }
            return found
        }
    }

    func setEnabled(_ enabled: Bool, userID: String) {
        queue.sync {
            try? execute(
                """
                INSERT INTO sync_accounts(user_id,enabled) VALUES(?,?)
                ON CONFLICT(user_id) DO UPDATE SET enabled=excluded.enabled
                """,
                [userID, enabled ? 1 : 0]
            )
        }
    }

    func setProgress(userID: String, cursor: Int64, checkpoint: Int64) {
        queue.sync {
            try? execute(
                """
                INSERT INTO sync_accounts(user_id,cursor,checkpoint) VALUES(?,?,?)
                ON CONFLICT(user_id) DO UPDATE SET
                  cursor=excluded.cursor,checkpoint=excluded.checkpoint
                """,
                [userID, cursor, checkpoint]
            )
        }
    }

    func knownEntities(userID: String, type: CloudSyncEntityType) -> [UUID: (revision: Int64, payload: Data)] {
        queue.sync {
            var result: [UUID: (Int64, Data)] = [:]
            query(
                "SELECT entity_id,revision,payload FROM sync_entities WHERE user_id=? AND entity_type=? AND deleted=0",
                [userID, type.rawValue]
            ) { row in
                if let id = UUID(uuidString: row.string(0)), let payload = row.data(2) {
                    result[id] = (row.int64(1), payload)
                }
            }
            return result
        }
    }

    func stageLocalChanges(userID: String, type: CloudSyncEntityType, entities: [UUID: Data]) {
        queue.sync {
            let known = knownEntitiesUnsafe(userID: userID, type: type)
            for (id, payload) in entities where known[id]?.payload != payload {
                let revision = known[id]?.revision ?? 0
                let mutation = vocabularyIncrement(
                    type: type, previous: known[id]?.payload, current: payload
                )
                upsertOutbox(
                    userID: userID, type: type, id: id,
                    operation: revision == 0 ? "create" : mutation?.operation ?? "update",
                    baseRevision: revision, payload: mutation?.payload ?? payload
                )
            }
            for (id, record) in known where entities[id] == nil {
                upsertOutbox(
                    userID: userID, type: type, id: id,
                    operation: "delete", baseRevision: record.revision, payload: record.payload
                )
            }
        }
    }

    func pending(userID: String, limit: Int = 100) -> [CloudSyncMutation] {
        queue.sync {
            var result: [CloudSyncMutation] = []
            query(
                """
                SELECT mutation_id,entity_type,entity_id,operation,base_revision,payload
                FROM sync_outbox WHERE user_id=? ORDER BY created_at LIMIT ?
                """,
                [userID, limit]
            ) { row in
                guard let mutationID = UUID(uuidString: row.string(0)),
                      let type = CloudSyncEntityType(rawValue: row.string(1)),
                      let entityID = UUID(uuidString: row.string(2)), let payload = row.data(5) else { return }
                result.append(CloudSyncMutation(
                    mutationID: mutationID, entityType: type, entityID: entityID,
                    operation: row.string(3), baseRevision: row.int64(4), payload: payload
                ))
            }
            return result
        }
    }

    func accept(
        _ results: [CloudSyncMutationResult], mutations: [CloudSyncMutation], userID: String,
        removeRejected: Bool = true
    ) {
        queue.sync {
            let mutationsByID = Dictionary(uniqueKeysWithValues: mutations.map { ($0.mutationID, $0) })
            for result in results {
                guard let mutation = mutationsByID[result.mutationID] else { continue }
                guard result.status == "accepted" || removeRejected else { continue }
                try? execute(
                    "DELETE FROM sync_outbox WHERE user_id=? AND mutation_id=?",
                    [userID, result.mutationID.uuidString]
                )
                guard result.status == "accepted" else { continue }
                if mutation.operation == "delete" || result.deleted {
                    try? execute(
                        """
                        UPDATE sync_entities SET revision=?,deleted=1
                        WHERE user_id=? AND entity_type=? AND entity_id=?
                        """,
                        [result.revision, userID, mutation.entityType.rawValue, mutation.entityID.uuidString]
                    )
                } else {
                    let acceptedPayload = result.current?.data ?? mutation.payload
                    upsertEntity(userID: userID, type: mutation.entityType, id: result.canonicalID,
                                 revision: result.revision, payload: acceptedPayload, deleted: false)
                    if result.canonicalID != mutation.entityID {
                        try? execute("DELETE FROM sync_entities WHERE user_id=? AND entity_type=? AND entity_id=?",
                                     [userID, mutation.entityType.rawValue, mutation.entityID.uuidString])
                    }
                }
            }
        }
    }

    private func vocabularyIncrement(
        type: CloudSyncEntityType, previous: Data?, current: Data
    ) -> (operation: String, payload: Data)? {
        guard type == .vocabulary, let previous,
              let old = try? JSONDecoder.cloudSyncStore.decode(VocabularyCloudPayload.self, from: previous),
              let new = try? JSONDecoder.cloudSyncStore.decode(VocabularyCloudPayload.self, from: current),
              old.term == new.term, old.source == new.source, old.createdAt == new.createdAt,
              new.occurrenceCount > old.occurrenceCount,
              let payload = try? JSONSerialization.data(withJSONObject: [
                  "delta": new.occurrenceCount - old.occurrenceCount
              ])
        else { return nil }
        return ("increment", payload)
    }

    func apply(change: CloudSyncChange, userID: String) {
        queue.sync {
            upsertEntity(userID: userID, type: change.entityType, id: change.entityID,
                         revision: change.revision, payload: change.payload.data, deleted: change.operation == "delete")
        }
    }

    private func knownEntitiesUnsafe(
        userID: String,
        type: CloudSyncEntityType
    ) -> [UUID: (revision: Int64, payload: Data)] {
        var result: [UUID: (Int64, Data)] = [:]
        query("SELECT entity_id,revision,payload FROM sync_entities WHERE user_id=? AND entity_type=? AND deleted=0",
              [userID, type.rawValue]) { row in
            if let id = UUID(uuidString: row.string(0)), let data = row.data(2) { result[id] = (row.int64(1), data) }
        }
        return result
    }

    private func upsertOutbox(userID: String, type: CloudSyncEntityType, id: UUID,
                              operation: String, baseRevision: Int64, payload: Data) {
        try? execute("DELETE FROM sync_outbox WHERE user_id=? AND entity_type=? AND entity_id=?",
                     [userID, type.rawValue, id.uuidString])
        try? execute(
            """
            INSERT INTO sync_outbox(
              user_id,mutation_id,entity_type,entity_id,operation,base_revision,payload,created_at
            ) VALUES(?,?,?,?,?,?,?,?)
            """,
            [
                userID, UUID().uuidString, type.rawValue, id.uuidString,
                operation, baseRevision, payload, Date().timeIntervalSince1970
            ]
        )
    }

    private func upsertEntity(userID: String, type: CloudSyncEntityType, id: UUID,
                              revision: Int64, payload: Data, deleted: Bool) {
        try? execute(
            """
            INSERT INTO sync_entities(user_id,entity_type,entity_id,revision,payload,deleted)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(user_id,entity_type,entity_id) DO UPDATE SET
              revision=excluded.revision,payload=excluded.payload,deleted=excluded.deleted
            """,
            [userID, type.rawValue, id.uuidString, revision, payload, deleted ? 1 : 0]
        )
    }

    private func execute(_ sql: String, _ values: [Any] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        bind(values, statement)
        while sqlite3_step(statement) == SQLITE_ROW {}
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw databaseError() }
    }

    private func query(_ sql: String, _ values: [Any], row: (SQLiteRow) -> Void) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(values, statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(SQLiteRow(statement: statement!)) }
    }

    private func bind(_ values: [Any], _ statement: OpaquePointer?) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, cloudSyncSQLiteTransient)
            case let value as Int: sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Data:
                _ = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), cloudSyncSQLiteTransient)
                }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func databaseError() -> NSError {
        NSError(domain: "CloudDataSyncSQLite", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
}

private extension JSONDecoder {
    static var cloudSyncStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct SQLiteRow {
    let statement: OpaquePointer
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func string(_ index: Int32) -> String { String(cString: sqlite3_column_text(statement, index)) }
    func data(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
