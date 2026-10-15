import Foundation
import SQLite3

extension SemanticFileStore {
    func prepareDiscoverySchema() throws {
        try sql("""
        CREATE TABLE IF NOT EXISTS scan_scope(value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scan_directories(path TEXT PRIMARY KEY,state TEXT NOT NULL);
        """)
    }

    /// Resume an interrupted directory walk only under the identical privacy/scope configuration.
    func beginDiscovery(scope: AskFileScope? = nil) throws {
        try lock.withLock {
            try prepareDiscoverySchema()
            let key = try scope.map {
                let groups = [$0.roots, $0.excludedPaths, $0.excludedFolderNames.sorted(),
                              $0.excludedExtensions.sorted(), $0.blocked, [String($0.includeHidden)]]
                let encoded = try JSONEncoder().encode(groups)
                return String(data: encoded, encoding: .utf8) ?? ""
            } ?? ""
            let row = try statement("SELECT value FROM scan_scope")
            let old = sqlite3_step(row) == SQLITE_ROW ? string(row, 0) : nil
            sqlite3_finalize(row)
            if old == key {
                // Directories may have changed while the process was absent. Revalidate the walk,
                // retaining file checkpoints and queued work; do not prune from an old snapshot.
                try transaction {
                    try sql("DELETE FROM discovery; UPDATE scan_directories SET state='pending'")
                }
                return
            }
            try transaction {
                try sql("DELETE FROM discovery; DELETE FROM scan_directories; DELETE FROM scan_scope;")
                try execute("INSERT INTO scan_scope VALUES(?)", [key])
                for root in scope?.roots ?? [] {
                    try execute("INSERT OR IGNORE INTO scan_directories VALUES(?,'pending')", [root])
                }
            }
        }
    }

    func nextDirectory() throws -> String? {
        try lock.withLock {
            let row = try statement("SELECT path FROM scan_directories WHERE state='pending' ORDER BY path LIMIT 1")
            defer { sqlite3_finalize(row) }
            let step = sqlite3_step(row)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
            return step == SQLITE_ROW ? string(row, 0) : nil
        }
    }

    func recordDirectories(_ paths: [String]) throws {
        try lock.withLock {
            try transaction {
                for path in paths {
                    try execute("INSERT OR IGNORE INTO scan_directories VALUES(?,'pending')", [path])
                }
            }
        }
    }

    func finishDirectory(_ path: String, failed: Bool) throws {
        try lock.withLock { try execute(
            "UPDATE scan_directories SET state=? WHERE path=?",
            [failed ? "failed" : "done", path]
        ) }
    }

    func discover(_ entries: [(String, SemanticMediaPriority)]) throws -> Int {
        try lock.withLock {
            try transaction {
                var inserted = 0
                for (path, priority) in entries {
                    try execute("INSERT OR IGNORE INTO discovery VALUES(?,?)", [path, priority.rawValue])
                    inserted += Int(sqlite3_changes(database))
                    try execute(
                        "INSERT OR IGNORE INTO work_queue(path,priority) VALUES(?,?)",
                        [path, priority.rawValue]
                    )
                }
                return inserted
            }
        }
    }

    func candidates(_ priority: SemanticMediaPriority, after: String) throws -> [String] {
        try lock.withLock {
            let row = try statement("SELECT path FROM discovery WHERE priority=? AND path>? ORDER BY path LIMIT 128")
            defer { sqlite3_finalize(row) }
            bind(row, [priority.rawValue, after])
            var paths: [String] = []
            var step = sqlite3_step(row)
            while step == SQLITE_ROW {
                paths.append(string(row, 0)); step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            return paths
        }
    }

    /// A failed subtree protects only that subtree. Decoder failures and empty files cannot block prune.
    func pruneDiscovered(cancelled: () -> Bool) throws {
        try lock.withLock {
            while true {
                if cancelled() {
                    throw CancellationError()
                }
                let removed = try transaction {
                    let row = try statement("""
                    SELECT path FROM (
                        SELECT path FROM files UNION SELECT path FROM jobs
                        UNION SELECT path FROM media_jobs UNION SELECT path FROM work_queue
                    ) AS candidate WHERE path NOT IN (SELECT path FROM discovery)
                    AND NOT EXISTS(SELECT 1 FROM scan_directories d WHERE d.state<>'done'
                        AND (d.path='/' OR candidate.path=d.path
                            OR substr(candidate.path,1,length(d.path)+1)=d.path||'/')) LIMIT 128
                    """)
                    var paths: [String] = []
                    do {
                        defer { sqlite3_finalize(row) }
                        var step = sqlite3_step(row)
                        while step == SQLITE_ROW {
                            paths.append(string(row, 0)); step = sqlite3_step(row)
                        }
                        guard step == SQLITE_DONE else { throw Failure.database }
                    }
                    for path in paths {
                        // Both committed content and unfinished private checkpoints follow the same scope.
                        // Foreign keys/triggers remove chunks, lexical terms and staged media segments.
                        for table in ["files", "jobs", "media_jobs", "work_queue"] {
                            try execute("DELETE FROM \(table) WHERE path=?", [path])
                        }
                    }
                    return paths.count
                }
                if removed == 0 {
                    break
                }
            }
            try sql("DELETE FROM scan_scope")
        }
    }
}
