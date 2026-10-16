import Foundation
import SQLite3

extension SemanticFileStore {
    // Initializers perform DDL only. Each keyset batch commits its generated rows and cursor together;
    // cancellation rolls back only this batch, while the previous FTS generation remains searchable.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func maintainSearchBatch(cancelled: () -> Bool) throws -> Bool {
        try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
        return try lock.withLock {
            guard let database else { throw Failure.database }
            return try SemanticSQLiteCancellation.read(database, cancelled: cancelled, background: true) {
                try transaction {
                    if try maintainProfileBatch() {
                        return true
                    }
                    if try maintainTotalsBatch() {
                        return true
                    }
                    let state =
                        try statement(
                            "SELECT page_cursor,page_done,lexical_cursor,lexical_done FROM search_migration WHERE id=1"
                        )
                    guard sqlite3_step(state) == SQLITE_ROW else { sqlite3_finalize(state); throw Failure.database }
                    let pageCursor = sqlite3_column_int64(state, 0), pageDone = sqlite3_column_int(state, 1) != 0
                    let lexicalCursor = sqlite3_column_int64(state, 2), lexicalDone = sqlite3_column_int(state, 3) != 0
                    sqlite3_finalize(state)
                    if !pageDone {
                        let rows = try statement("SELECT id FROM chunks WHERE id>? ORDER BY id LIMIT 128")
                        bind(rows, [pageCursor])
                        var ids: [Int64] = [], step = sqlite3_step(rows)
                        while step == SQLITE_ROW {
                            if cancelled() {
                                sqlite3_finalize(rows); throw CancellationError()
                            }
                            ids.append(sqlite3_column_int64(rows, 0)); step = sqlite3_step(rows)
                        }
                        sqlite3_finalize(rows)
                        guard step == SQLITE_DONE else { throw Failure.database }
                        for page in Set(ids.map { $0 / 256 }).sorted() {
                            try execute("INSERT OR IGNORE INTO vector_pages VALUES(?,0)", [page])
                        }
                        if let last = ids.last {
                            try execute("""
                            INSERT OR IGNORE INTO vector_pending SELECT id,path,COALESCE(generation,'') FROM chunks
                                WHERE id>? AND id<=? AND length(vector)=0
                            """, [pageCursor, last])
                        }
                        try recordLocked(.migrationRows, count: ids.count)
                        try execute("UPDATE search_migration SET page_cursor=?,page_done=? WHERE id=1",
                                    [ids.last ?? pageCursor, ids.count < 128 ? 1 : 0])
                        return true
                    }
                    let rows = try statement(lexicalDone ? """
                    SELECT d.id,c.text FROM search_dirty d LEFT JOIN chunks c ON c.id=d.id ORDER BY d.id LIMIT 128
                    """ : "SELECT id,text FROM chunks WHERE id>? ORDER BY id LIMIT 128")
                    if !lexicalDone {
                        bind(rows, [lexicalCursor])
                    }
                    var entries: [(Int64, String?)] = [], step = sqlite3_step(rows)
                    while step == SQLITE_ROW {
                        if cancelled() {
                            sqlite3_finalize(rows); throw CancellationError()
                        }
                        entries.append((
                            sqlite3_column_int64(rows, 0),
                            sqlite3_column_type(rows, 1) == SQLITE_NULL ? nil : string(rows, 1)
                        ))
                        step = sqlite3_step(rows)
                    }
                    sqlite3_finalize(rows)
                    guard step == SQLITE_DONE else { throw Failure.database }
                    for (id, text) in entries {
                        if cancelled() {
                            throw CancellationError()
                        }
                        try writeSearchGeneration(id, text: text)
                    }
                    try recordLocked(.migrationRows, count: entries.count)
                    if !lexicalDone {
                        try execute("UPDATE search_migration SET lexical_cursor=?,lexical_done=? WHERE id=1",
                                    [entries.last?.0 ?? lexicalCursor, entries.count < 128 ? 1 : 0])
                    }
                    return !entries.isEmpty || !lexicalDone
                }
            }
        }
    }
}

extension SemanticFileStore {
    private func maintainProfileBatch() throws -> Bool {
        let state = try statement("SELECT target FROM profile_reset WHERE id=1")
        let step = sqlite3_step(state)
        let target = step == SQLITE_ROW ? string(state, 0) : nil
        sqlite3_finalize(state)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
        guard let target else { return false }
        for table in [
            "chunks",
            "files",
            "jobs",
            "media_jobs",
            "work_queue",
            "discovery",
            "scan_directories",
            "scan_scope",
            "scan_roots",
            "scan_cursors",
            "scan_requests"
        ] {
            // Row-limited deletion keeps even a single book with a million chunks interruptible.
            try sql("DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) LIMIT 128)")
            let changed = Int(sqlite3_changes(database))
            if changed > 0 {
                try recordLocked(.migrationRows, count: changed); return true
            }
        }
        try sql("DELETE FROM profile")
        try execute("INSERT INTO profile VALUES(?)", [target])
        try sql("DELETE FROM profile_reset")
        return true
    }
}
