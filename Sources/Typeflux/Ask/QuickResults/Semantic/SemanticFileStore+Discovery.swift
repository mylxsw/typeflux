import Foundation
import SQLite3

extension SemanticFileStore {
    func prepareDiscoverySchema() throws {
        try sql("""
        CREATE TABLE IF NOT EXISTS scan_scope(value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scan_directories(path TEXT PRIMARY KEY,state TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scan_roots(path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS scan_cursors(path TEXT PRIMARY KEY,cursor TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scan_requests(path TEXT PRIMARY KEY,root TEXT NOT NULL,revision INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS scan_request_roots ON scan_requests(root);
        CREATE TABLE IF NOT EXISTS scan_clock(value INTEGER NOT NULL);
        INSERT INTO scan_clock SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM scan_clock);
        CREATE INDEX IF NOT EXISTS scan_directories_state_path ON scan_directories(state,path);
        CREATE TABLE IF NOT EXISTS scan_checkpoint(scope TEXT NOT NULL,event_id INTEGER NOT NULL,
            volume_signature TEXT NOT NULL);
        """)
    }

    static func discoveryKey(_ scope: AskFileScope) throws -> String {
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)],
                      SemanticFilePolicy.extensions.sorted()]
        return String(data: try JSONEncoder().encode(groups), encoding: .utf8) ?? ""
    }

    func completedEventID(scope: AskFileScope, volumeSignature: String) throws -> UInt64? {
        try lock.withLock {
            let row = try statement("SELECT event_id FROM scan_checkpoint WHERE scope=? AND volume_signature=?")
            defer { sqlite3_finalize(row) }
            bind(row, [try Self.discoveryKey(scope), volumeSignature])
            return sqlite3_step(row) == SQLITE_ROW ? UInt64(bitPattern: sqlite3_column_int64(row, 0)) : nil
        }
    }

    func hasPendingPrune() throws -> Bool {
        try lock.withLock {
            let row = try statement("SELECT 1 FROM scan_scope LIMIT 1")
            defer { sqlite3_finalize(row) }
            return sqlite3_step(row) == SQLITE_ROW
        }
    }

    func failedDirectories() throws -> [String] {
        try lock.withLock {
            let row = try statement("SELECT path FROM scan_directories WHERE state='failed' ORDER BY path")
            defer { sqlite3_finalize(row) }
            var paths: [String] = []
            var step = sqlite3_step(row)
            while step == SQLITE_ROW { paths.append(string(row, 0)); step = sqlite3_step(row) }
            guard step == SQLITE_DONE else { throw Failure.database }
            return paths
        }
    }

    func invalidateDiscovery() throws {
        try lock.withLock {
            try sql("DELETE FROM scan_checkpoint; DELETE FROM scan_scope; DELETE FROM scan_cursors")
        }
    }

    func saveEventID(_ eventID: UInt64, scope: AskFileScope, volumeSignature: String?) throws {
        guard let volumeSignature else { return }
        try lock.withLock {
            try transaction {
                try sql("DELETE FROM scan_checkpoint")
                try execute("INSERT INTO scan_checkpoint VALUES(?,?,?)",
                            [try Self.discoveryKey(scope), Int64(bitPattern: eventID), volumeSignature])
            }
        }
    }

    /// Resume an interrupted directory walk only under the identical privacy/scope configuration.
    func beginDiscovery(scope: AskFileScope? = nil, roots: [String]? = nil) throws {
        try lock.withLock {
            try prepareDiscoverySchema()
            let bounds = roots ?? ["/"]
            let key = try scope.map {
                let groups = [$0.roots, $0.excludedPaths, $0.excludedFolderNames.sorted(),
                              $0.excludedExtensions.sorted(), $0.blocked, [String($0.includeHidden)], bounds,
                              SemanticFilePolicy.extensions.sorted()]
                let encoded = try JSONEncoder().encode(groups)
                return String(data: encoded, encoding: .utf8) ?? ""
            } ?? ""
            let row = try statement("SELECT value FROM scan_scope")
            let old = sqlite3_step(row) == SQLITE_ROW ? string(row, 0) : nil
            sqlite3_finalize(row)
            if old == key {
                try sql("UPDATE scan_directories SET state='pending' WHERE state='failed'")
                // Durable FSEvents replay covers changes made while absent. Keep committed directory
                // cursors and completed subtrees instead of restarting an interrupted walk.
                return
            }
            try transaction {
                try sql(
                    """
                    DELETE FROM discovery; DELETE FROM scan_directories; DELETE FROM scan_scope;
                    DELETE FROM scan_roots; DELETE FROM scan_cursors;
                    """
                )
                try execute("INSERT INTO scan_scope VALUES(?)", [key])
                for root in bounds {
                    try execute("INSERT INTO scan_roots VALUES(?)", [root])
                }
                for root in roots ?? scope?.roots ?? [] {
                    try execute("INSERT OR IGNORE INTO scan_directories VALUES(?,'pending')", [root])
                }
            }
        }
    }

    /// Replace only one changed tree's discovery snapshot. Failed directories still protect their descendants.
    func beginSubtree(_ path: String) throws {
        try lock.withLock {
            try transaction {
                for table in ["discovery", "scan_directories"] {
                    try execute("DELETE FROM \(table) WHERE path=? OR substr(path,1,length(?)+1)=?||'/'",
                                [path, path, path])
                }
                try execute("INSERT INTO scan_directories VALUES(?,'pending')", [path])
            }
        }
    }

    func pruneSubtree(_ path: String, cancelled: () -> Bool) throws {
        try lock.withLock {
            while true {
                if cancelled() { throw CancellationError() }
                let removed = try transaction {
                    let row = try statement("""
                    SELECT path FROM (
                        SELECT path FROM files UNION SELECT path FROM jobs
                        UNION SELECT path FROM media_jobs UNION SELECT path FROM work_queue
                    ) AS candidate WHERE (candidate.path=? OR
                        substr(candidate.path,1,length(?)+1)=?||'/')
                    AND candidate.path NOT IN (SELECT path FROM discovery)
                    AND NOT EXISTS(SELECT 1 FROM scan_directories d WHERE d.state<>'done'
                        AND (d.path='/' OR candidate.path=d.path
                            OR substr(candidate.path,1,length(d.path)+1)=d.path||'/')) LIMIT 128
                    """)
                    bind(row, [path, path, path])
                    var paths: [String] = []
                    var step = sqlite3_step(row)
                    while step == SQLITE_ROW { paths.append(string(row, 0)); step = sqlite3_step(row) }
                    sqlite3_finalize(row)
                    guard step == SQLITE_DONE else { throw Failure.database }
                    for candidate in paths {
                        for table in ["files", "jobs", "media_jobs", "work_queue"] {
                            try execute("DELETE FROM \(table) WHERE path=?", [candidate])
                        }
                    }
                    return paths.count
                }
                if removed == 0 { break }
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

    func directoryCursor(_ path: String) throws -> AskDirectoryCursor {
        try lock.withLock {
            let row = try statement("SELECT cursor FROM scan_cursors WHERE path=?")
            defer { sqlite3_finalize(row) }
            bind(row, [path])
            let step = sqlite3_step(row)
            if step == SQLITE_DONE {
                return .init()
            }
            guard step == SQLITE_ROW, let data = string(row, 0).data(using: .utf8),
                  let cursor = try? JSONDecoder().decode(AskDirectoryCursor.self, from: data)
            else { throw Failure.database }
            return cursor
        }
    }

    func checkpointDirectory(_ path: String, cursor: AskDirectoryCursor?) throws {
        try lock.withLock {
            if let cursor {
                let data = try JSONEncoder().encode(cursor)
                try execute(
                    "INSERT OR REPLACE INTO scan_cursors VALUES(?,?)",
                    [path, String(data: data, encoding: .utf8) ?? ""]
                )
            } else {
                try execute("DELETE FROM scan_cursors WHERE path=?", [path])
            }
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
    func pruneDiscovered(cancelled: () -> Bool, documentsOnly: Bool = false) throws {
        let typeFilter = documentsOnly ? "AND (" + SemanticFilePolicy.documentExtensions.sorted().map {
            "lower(candidate.path) GLOB '*." + $0 + "'"
        }.joined(separator: " OR ") + ")" : ""
        try lock.withLock {
            guard let database else { throw Failure.database }
            try SemanticSQLiteCancellation.read(database, cancelled: cancelled, background: true) {
                while true {
                    if cancelled() {
                        throw CancellationError()
                    }
                    let removed = try transaction {
                        let row = try statement("""
                        SELECT path FROM (
                            SELECT path FROM files UNION SELECT path FROM jobs
                            UNION SELECT path FROM media_jobs UNION SELECT path FROM work_queue
                        ) AS candidate WHERE path NOT IN (SELECT path FROM discovery) \(typeFilter)
                        AND EXISTS(SELECT 1 FROM scan_roots r WHERE r.path='/' OR candidate.path=r.path
                            OR substr(candidate.path,1,length(r.path)+1)=r.path||'/')
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
}
