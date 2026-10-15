import Accelerate
import Foundation
import SQLite3

private let semanticTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A separate WAL database. A file, its chunks, lexical terms and vectors commit together.
/// Serialized by the lock; no main-actor disk I/O and no shared filename-index state.
final class SemanticFileStore: @unchecked Sendable {
    enum Failure: Error { case database, invalidVector }
    private let lock = NSLock()
    private var database: OpaquePointer?
    let url: URL

    init(url: URL, profile: String = SemanticFilePolicy.profile) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(
            url.path,
            &self.database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) ==
            SQLITE_OK else {
            sqlite3_close(self.database); self.database = nil; throw Failure.database
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(self.database, 1000)
            try self.sql("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")
            try self.sql(
                """
                CREATE TABLE IF NOT EXISTS profile(value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, modified REAL NOT NULL, bytes INTEGER NOT NULL);
                """
            )
            try self.sql(
                """
                CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE, text TEXT NOT NULL, page INTEGER, vector BLOB NOT NULL);
                """
            )
            try self.sql(
                """
                CREATE INDEX IF NOT EXISTS chunk_paths ON chunks(path);
                CREATE VIRTUAL TABLE IF NOT EXISTS lexical USING fts5(terms);
                """
            )
            try self.sql(
                """
                CREATE TRIGGER IF NOT EXISTS remove_lexical AFTER DELETE ON chunks BEGIN DELETE FROM lexical WHERE rowid=old.id;
                END;
                """
            )
            try self.prepareContentSchema()
            let existing = try statement("SELECT value FROM profile")
            let old = sqlite3_step(existing) == SQLITE_ROW ? self.string(existing, 0) : nil
            sqlite3_finalize(existing)
            if old != profile {
                try self.sql("BEGIN IMMEDIATE; DELETE FROM files; DELETE FROM lexical; DELETE FROM profile;")
                do { try self.execute("INSERT INTO profile VALUES(?)", [profile]); try self.sql("COMMIT;") } catch {
                    try? self.sql("ROLLBACK"); throw error
                }
            }
        } catch { sqlite3_close(self.database); self.database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    func unchanged(path: String, modified: Date, bytes: Int64) throws -> Bool {
        try self.lock.withLock {
            let stmt = try statement("SELECT modified, bytes FROM files WHERE path=?")
            defer { sqlite3_finalize(stmt) }
            self.bind(stmt, [path])
            return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_double(stmt, 0) == modified.timeIntervalSince1970
                && sqlite3_column_int64(stmt, 1) == bytes
        }
    }

    func replace(path: String, modified: Date, bytes: Int64, chunks: [SemanticChunk], vectors: [[Float]]) throws {
        guard chunks.count == vectors.count, vectors.allSatisfy(Self.valid) else { throw Failure.invalidVector }
        try self.lock.withLock {
            try self.sql("BEGIN IMMEDIATE")
            do {
                try self.execute("DELETE FROM files WHERE path=?", [path])
                try self.execute("INSERT INTO files VALUES(?,?,?)", [path, modified.timeIntervalSince1970, bytes])
                for (chunk, vector) in zip(chunks, vectors) {
                    let data = vector.withUnsafeBytes { Data($0) }
                    try self.execute(
                        "INSERT INTO chunks(path,text,page,time,vector) VALUES(?,?,?,?,?)",
                        [path, chunk.text, chunk.page as Any, chunk.time as Any, data]
                    )
                    let id = sqlite3_last_insert_rowid(database)
                    try execute(
                        "INSERT INTO lexical(rowid,terms) VALUES(?,?)",
                        [id, SemanticFilePolicy.terms(chunk.text)]
                    )
                }
                try self.sql("COMMIT")
            } catch { try? self.sql("ROLLBACK"); throw error }
        }
    }

    func remove(_ path: String) throws {
        try self.lock.withLock { try self.execute("DELETE FROM files WHERE path=?", [path]) }
    }

    func prune(keeping paths: Set<String>, cancelled: () -> Bool) throws {
        try self.lock.withLock {
            let stmt = try statement("SELECT path FROM files")
            var stale: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = self.string(stmt, 0)
                if !paths.contains(path) {
                    stale.append(path)
                }
            }
            sqlite3_finalize(stmt)
            guard !cancelled() else { throw CancellationError() }
            try self.sql("BEGIN IMMEDIATE")
            do {
                for path in stale {
                    if cancelled() {
                        throw CancellationError()
                    }
                    try self.execute("DELETE FROM files WHERE path=?", [path])
                }
                try self.sql("COMMIT")
            } catch { try? self.sql("ROLLBACK"); throw error }
        }
    }

    func clear() throws {
        try self.lock.withLock {
            try self.sql("DELETE FROM files; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        }
    }

    func counts() throws -> (files: Int, chunks: Int) {
        try self.lock.withLock { try (self.count("files"), self.count("chunks")) }
    }

    // Scope/type/filter checks precede ranking; forbidden rows cannot consume TopK slots.
    // Keep permission checks and the bounded TopK loop together.
    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    func search(vector: [Float], text: String, query: AskSearchQuery, type: AskFileType,
                scope: AskFileScope, limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        guard limit > 0, Self.valid(vector) else { return [] }
        return try self.lock.withLock {
            let terms = SemanticFilePolicy.searchTerms(text)
                .prefix(64)
            var lexical = Set<Int64>()
            if !terms.isEmpty {
                let stmt = try statement("SELECT rowid FROM lexical WHERE lexical MATCH ?")
                defer { sqlite3_finalize(stmt) }
                self.bind(stmt, [terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")])
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if cancelled() {
                        throw CancellationError()
                    }
                    lexical.insert(sqlite3_column_int64(stmt, 0))
                }
            }
            let stmt = try statement(
                """
                SELECT c.id,c.path,c.page,c.vector,f.modified,c.time
                FROM chunks c JOIN files f ON f.path=c.path ORDER BY c.id
                """
            )
            defer { sqlite3_finalize(stmt) }
            var best: [(id: Int64, hit: AskFileHit)] = []
            var previousPath: String?, allowed = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if cancelled() { throw CancellationError() }
                let path = self.string(stmt, 1)
                if previousPath != path {
                    previousPath = path
                    let ext = (path as NSString).pathExtension.lowercased()
                    allowed = scope.includes(path, isDirectory: false) && SemanticFilePolicy.allows(path)
                        && type.matches(kind: .file, extension: ext)
                        && (query.fileExtension == nil || query.fileExtension == ext)
                    if let folder = query.folder {
                        let place = AskSearchText.normalize((path as NSString).deletingLastPathComponent)
                        allowed = allowed && AskFileIndexState.contains(place, folder)
                    }
                }
                guard allowed, sqlite3_column_bytes(stmt, 3) == SemanticFilePolicy.dimension * 4,
                      let raw = sqlite3_column_blob(stmt, 3) else { continue }
                // SQLite owns this blob until the next step; score it directly without allocating 768 Floats per row.
                let cosine = vector.withUnsafeBufferPointer {
                    Double(cblas_sdot(Int32($0.count), $0.baseAddress!, 1, raw.assumingMemoryBound(to: Float.self), 1))
                }
                let id = sqlite3_column_int64(stmt, 0), lexicalMatch = lexical.contains(id)
                guard cosine.isFinite, cosine >= 0.35 || lexicalMatch else { continue }
                let score = max(0, cosine) * 0.7 + (lexicalMatch ? 0.18 : 0)
                if let existing = best.firstIndex(where: { $0.hit.path == path }) {
                    if best[existing].hit.score >= score { continue }
                    best.remove(at: existing)
                }
                let page = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2))
                let value = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
                let time = value.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? $0 : nil }
                let hit = AskFileHit(path: path, name: (path as NSString).lastPathComponent, kind: .file,
                                     modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                                     score: score, evidence: .init(text: "", page: page, time: time))
                best.append((id, hit))
                best.sort { $0.hit.score == $1.hit.score ? $0.hit.path < $1.hit.path : $0.hit.score > $1.hit.score }
                if best.count > min(100, limit) { best.removeLast() }
            }
            // Materialize passages only for the winning files, not for every scanned chunk.
            return try best.map { candidate in
                let textRow = try statement("SELECT text FROM chunks WHERE id=?")
                defer { sqlite3_finalize(textRow) }
                self.bind(textRow, [candidate.id])
                var hit = candidate.hit
                if sqlite3_step(textRow) == SQLITE_ROW {
                    hit.evidence?.text = String(self.string(textRow, 0).prefix(180))
                }
                return hit
            }
        }
    }

    static func valid(_ vector: [Float]) -> Bool {
        guard vector.count == SemanticFilePolicy.dimension, vector.allSatisfy(\.isFinite) else { return false }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(norm - 1) < 0.02
    }

    private func count(_ table: String) throws -> Int {
        let stmt = try statement("SELECT count(*) FROM " + table)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func sql(_ value: String) throws {
        guard sqlite3_exec(self.database, value, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(self.database, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw Failure.database }
        return stmt
    }

    private func execute(_ sql: String, _ values: [Any]) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        self.bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.database }
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Any]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let element as String: sqlite3_bind_text(stmt, position, element, -1, semanticTransient)
            case let element as Int64: sqlite3_bind_int64(stmt, position, element)
            case let element as Int: sqlite3_bind_int64(stmt, position, Int64(element))
            case let element as Double: sqlite3_bind_double(stmt, position, element)
            case let element as Data: _ = element.withUnsafeBytes { sqlite3_bind_blob(
                    stmt,
                    position,
                    $0.baseAddress,
                    Int32(element.count),
                    semanticTransient
                ) }
            default: sqlite3_bind_null(stmt, position)
            }
        }
    }

    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}

extension SemanticFileStore {
    private func prepareContentSchema() throws {
        let columns = try statement("PRAGMA table_info(chunks)")
        var hasTime = false
        while sqlite3_step(columns) == SQLITE_ROW { hasTime = hasTime || self.string(columns, 1) == "time" }
        sqlite3_finalize(columns)
        if !hasTime { try self.sql("ALTER TABLE chunks ADD COLUMN time REAL") }
        try self.sql("CREATE TEMP TABLE discovery(path TEXT PRIMARY KEY, priority INTEGER NOT NULL);")
        try self.sql("CREATE INDEX discovery_priority ON discovery(priority,path);")
        try self.sql("CREATE TEMP TABLE media_stage(time REAL,vector BLOB NOT NULL);")
    }

    func beginDiscovery() throws {
        try lock.withLock { try sql("DELETE FROM discovery") }
    }

    func discover(_ entries: [(String, SemanticMediaPriority)]) throws -> Int {
        try lock.withLock {
            try sql("BEGIN IMMEDIATE")
            do {
                var inserted = 0
                for (path, priority) in entries {
                    try execute("INSERT OR IGNORE INTO discovery VALUES(?,?)", [path, priority.rawValue])
                    inserted += Int(sqlite3_changes(database))
                }
                try sql("COMMIT"); return inserted
            } catch { try? sql("ROLLBACK"); throw error }
        }
    }

    func candidates(_ priority: SemanticMediaPriority, after: String) throws -> [String] {
        try lock.withLock {
            let row = try statement("SELECT path FROM discovery WHERE priority=? AND path>? ORDER BY path LIMIT 128")
            defer { sqlite3_finalize(row) }
            bind(row, [priority.rawValue, after])
            var paths: [String] = []
            while sqlite3_step(row) == SQLITE_ROW { paths.append(string(row, 0)) }
            return paths
        }
    }

    func pruneDiscovered(cancelled: () -> Bool) throws {
        try lock.withLock {
            while true {
                if cancelled() { throw CancellationError() }
                try sql("""
                    DELETE FROM files WHERE path IN
                    (SELECT path FROM files WHERE path NOT IN (SELECT path FROM discovery) LIMIT 128)
                    """)
                if sqlite3_changes(database) == 0 { return }
            }
        }
    }

    func beginMedia() throws { try lock.withLock { try sql("DELETE FROM media_stage") } }

    func stageMedia(_ vector: [Float], time: TimeInterval?) throws {
        guard Self.valid(vector), time.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw Failure.invalidVector }
        try lock.withLock {
            try execute("INSERT INTO media_stage VALUES(?,?)", [time as Any, vector.withUnsafeBytes { Data($0) }])
        }
    }

    func commitMedia(path: String, modified: Date, bytes: Int64) throws -> Bool {
        try lock.withLock {
            guard try count("media_stage") > 0 else { return false }
            try sql("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM files WHERE path=?", [path])
                try execute("INSERT INTO files VALUES(?,?,?)", [path, modified.timeIntervalSince1970, bytes])
                try execute("INSERT INTO chunks(path,text,time,vector) SELECT ?,'',time,vector FROM media_stage",
                            [path])
                try sql("DELETE FROM media_stage; COMMIT"); return true
            } catch { try? sql("ROLLBACK"); throw error }
        }
    }

    func destroy() throws {
        try lock.withLock {
            guard sqlite3_close(database) == SQLITE_OK else { throw Failure.database }
            database = nil
            try Self.removeFiles(at: url)
        }
    }

    /// Also works when a corrupt database could not be opened during preparation.
    static func removeFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

}
