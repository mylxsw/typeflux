import Foundation
import SQLite3

extension SemanticFileStore {
    /// Count publication once per chunk. The keyset backfill and SQL triggers also cover older writers.
    /// Reads are constant-size; refreshing settings never enumerates every file or counts the chunk table.
    func prepareTotalsSchema() throws {
        try sql("""
        CREATE TABLE IF NOT EXISTS index_totals(id INTEGER PRIMARY KEY CHECK(id=1),documents INTEGER NOT NULL DEFAULT 0,
            images INTEGER NOT NULL DEFAULT 0,audio INTEGER NOT NULL DEFAULT 0,videos INTEGER NOT NULL DEFAULT 0,chunks INTEGER NOT NULL DEFAULT 0);
        INSERT OR IGNORE INTO index_totals(id) VALUES(1);
        CREATE TABLE IF NOT EXISTS counted_chunks(id INTEGER PRIMARY KEY,path TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS counted_chunk_path ON counted_chunks(path);
        CREATE TABLE IF NOT EXISTS counted_files(path TEXT PRIMARY KEY,amount INTEGER NOT NULL,kind INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS totals_migration(id INTEGER PRIMARY KEY CHECK(id=1),cursor INTEGER NOT NULL DEFAULT 0,done INTEGER NOT NULL DEFAULT 0);
        INSERT OR IGNORE INTO totals_migration(id,done) SELECT 1,NOT EXISTS(SELECT 1 FROM chunks LIMIT 1);
        """)
        let groups: [(Set<String>, Int)] = [
            (SemanticMediaPriority.images, 1),
            (SemanticMediaPriority.audioExtensions, 2),
            (SemanticMediaPriority.videoExtensions, 3)
        ]
        let kind = "CASE " + groups.map { extensions, value in
            "WHEN " + extensions.sorted().map { "lower(new.path) GLOB '*." + $0 + "'" }.joined(separator: " OR ") + " THEN \(value)"
        }.joined(separator: " ") + " ELSE 0 END"

        try sql("""
        CREATE TRIGGER IF NOT EXISTS totals_count AFTER INSERT ON counted_chunks BEGIN
            INSERT INTO counted_files(path,amount,kind) VALUES(new.path,1,\(kind))
                ON CONFLICT(path) DO UPDATE SET amount=amount+1;
            UPDATE index_totals SET chunks=chunks+1,
                documents=documents+(SELECT amount=1 AND kind=0 FROM counted_files WHERE path=new.path),
                images=images+(SELECT amount=1 AND kind=1 FROM counted_files WHERE path=new.path),
                audio=audio+(SELECT amount=1 AND kind=2 FROM counted_files WHERE path=new.path),
                videos=videos+(SELECT amount=1 AND kind=3 FROM counted_files WHERE path=new.path) WHERE id=1;
        END;
        CREATE TRIGGER IF NOT EXISTS totals_uncount AFTER DELETE ON counted_chunks BEGIN
            UPDATE index_totals SET chunks=chunks-1,
                documents=documents-(SELECT amount=1 AND kind=0 FROM counted_files WHERE path=old.path),
                images=images-(SELECT amount=1 AND kind=1 FROM counted_files WHERE path=old.path),
                audio=audio-(SELECT amount=1 AND kind=2 FROM counted_files WHERE path=old.path),
                videos=videos-(SELECT amount=1 AND kind=3 FROM counted_files WHERE path=old.path) WHERE id=1;
            UPDATE counted_files SET amount=amount-1 WHERE path=old.path;
            DELETE FROM counted_files WHERE path=old.path AND amount=0;
        END;
        CREATE TRIGGER IF NOT EXISTS totals_insert AFTER INSERT ON chunks BEGIN
            INSERT OR IGNORE INTO counted_chunks VALUES(new.id,new.path);
        END;
        CREATE TRIGGER IF NOT EXISTS totals_delete AFTER DELETE ON chunks BEGIN
            DELETE FROM counted_chunks WHERE id=old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS totals_path AFTER UPDATE OF id,path ON chunks BEGIN
            DELETE FROM counted_chunks WHERE id=old.id;
            INSERT OR IGNORE INTO counted_chunks VALUES(new.id,new.path);
        END;
        """)
    }

    func maintainTotalsBatch() throws -> Bool {
        let state = try statement("SELECT cursor,done FROM totals_migration WHERE id=1")
        guard sqlite3_step(state) == SQLITE_ROW else { sqlite3_finalize(state); throw Failure.database }
        let cursor = sqlite3_column_int64(state, 0), done = sqlite3_column_int(state, 1) != 0
        sqlite3_finalize(state)
        if done {
            return false
        }
        let row = try statement("SELECT id,path FROM chunks WHERE id>? ORDER BY id LIMIT 128")
        bind(row, [cursor]); defer { sqlite3_finalize(row) }
        var last = cursor, count = 0, step = sqlite3_step(row)
        while step == SQLITE_ROW {
            last = sqlite3_column_int64(row, 0); count += 1
            try execute("INSERT OR IGNORE INTO counted_chunks VALUES(?,?)", [last, string(row, 1)])
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw Failure.database }
        try execute("UPDATE totals_migration SET cursor=?,done=? WHERE id=1", [last, count < 128 ? 1 : 0])
        try recordLocked(.migrationRows, count: count)
        return true
    }
}
