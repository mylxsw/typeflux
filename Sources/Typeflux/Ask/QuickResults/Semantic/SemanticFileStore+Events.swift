import Foundation
import SQLite3

extension SemanticFileStore {
    struct ScanRequest {
        var path: String
        var revision: Int64
    }

    func acceptEvents(_ events: [SemanticIndexEvents.Entry], cancelled: () -> Bool = { false }) throws {
        try lock.withLock {
            guard !cancelled() else { throw CancellationError() }
            try transaction {
                try sql("UPDATE scan_clock SET value=value+1")
                for event in events {
                    guard !cancelled() else { throw CancellationError() }
                    if event.subtree {
                        try enqueueSubtree(event.path, root: event.root)
                    } else {
                        try execute(
                            "INSERT OR IGNORE INTO discovery VALUES(?,?)",
                            [event.path, SemanticMediaPriority.of(event.path).rawValue]
                        )
                        try execute("INSERT OR IGNORE INTO work_queue(path,priority) VALUES(?,?)",
                                    [event.path, SemanticMediaPriority.of(event.path).rawValue])
                    }
                }
                try recordLocked(.eventTasks, count: events.count)
                guard !cancelled() else { throw CancellationError() }
            }
        }
    }

    private func enqueueSubtree(_ path: String, root: String) throws {
        let ancestor = try statement("""
        SELECT path FROM scan_requests WHERE root=? AND (path=? OR path='/' OR substr(?,1,length(path)+1)=path||'/') LIMIT 1
        """)
        bind(ancestor, [root, path, path])
        let parent = sqlite3_step(ancestor) == SQLITE_ROW ? string(ancestor, 0) : nil
        sqlite3_finalize(ancestor)
        if let parent {
            try execute("UPDATE scan_requests SET revision=(SELECT value FROM scan_clock) WHERE path=?", [parent])
            return
        }
        try execute("DELETE FROM scan_requests WHERE root=? AND (path=? OR substr(path,1,length(?)+1)=?||'/')",
                    [root, path, path, path])
        try execute("INSERT OR REPLACE INTO scan_requests VALUES(?,?,(SELECT value FROM scan_clock))", [path, root])
        let count = try statement("SELECT count(*) FROM scan_requests WHERE root=?")
        bind(count, [root])
        let overflow = sqlite3_step(count) == SQLITE_ROW && sqlite3_column_int(count, 0) > 128
        sqlite3_finalize(count)
        if overflow {
            try execute("DELETE FROM scan_requests WHERE root=?", [root])
            try execute("INSERT INTO scan_requests VALUES(?,?,(SELECT value FROM scan_clock))", [root, root])
        }
    }

    func nextScanRequest() throws -> ScanRequest? {
        try lock.withLock {
            let row = try statement("SELECT path,revision FROM scan_requests ORDER BY revision,path LIMIT 1")
            defer { sqlite3_finalize(row) }
            let step = sqlite3_step(row)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
            return step == SQLITE_ROW ? .init(path: string(row, 0), revision: sqlite3_column_int64(row, 1)) : nil
        }
    }

    func finishScanRequest(_ request: ScanRequest) throws {
        try lock.withLock {
            try execute("DELETE FROM scan_requests WHERE path=? AND revision=?", [request.path, request.revision])
        }
    }

    func hasQueuedWork() throws -> Bool {
        try lock.withLock {
            let row = try statement("""
            SELECT 1 FROM work_queue w WHERE w.path IN (SELECT path FROM discovery) OR NOT EXISTS(
                SELECT 1 FROM scan_directories d WHERE d.state<>'done' AND
                (d.path='/' OR w.path=d.path OR substr(w.path,1,length(d.path)+1)=d.path||'/'))
            UNION ALL SELECT 1 FROM scan_requests LIMIT 1
            """)
            defer { sqlite3_finalize(row) }
            let step = sqlite3_step(row)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
            return step == SQLITE_ROW
        }
    }
}
