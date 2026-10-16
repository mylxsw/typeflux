import Foundation
import SQLite3

private let semanticTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A separate WAL database. Each content/checkpoint batch and each vector batch commits atomically.
/// Writes are serialized; each search channel owns an independent WAL reader and lock.
final class SemanticFileStore: @unchecked Sendable {
    enum Failure: Error { case database, invalidVector }
    /// Files with published content, including partial documents; discovered candidates are separate.
    struct Counts: Equatable, Sendable {
        var documents = 0
        var images = 0
        var audio = 0
        var videos = 0
        var chunks = 0

        var files: Int {
            documents + images + audio + videos
        }
    }

    let lock = NSLock()
    var database: OpaquePointer?
    private var lexicalReader: SemanticLexicalReader?
    private var vectorReader: SemanticVectorReader?
    let url: URL

    // Keep schema migration and reader startup in one initialization failure boundary.
    // swiftlint:disable:next function_body_length
    init(url: URL, profile: String = SemanticFilePolicy.profile) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) ==
            SQLITE_OK else {
            sqlite3_close(database); database = nil; throw Failure.database
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(database, 1000)
            try sql("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")
            try sql(
                """
                CREATE TABLE IF NOT EXISTS profile(value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, modified REAL NOT NULL, bytes INTEGER NOT NULL);
                """
            )
            try sql(
                """
                CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE, text TEXT NOT NULL, page INTEGER, vector BLOB NOT NULL);
                """
            )
            try sql(
                """
                CREATE INDEX IF NOT EXISTS chunk_paths ON chunks(path);
                CREATE VIRTUAL TABLE IF NOT EXISTS lexical USING fts5(terms);
                """
            )
            try sql(
                """
                CREATE TRIGGER IF NOT EXISTS remove_lexical AFTER DELETE ON chunks BEGIN DELETE FROM lexical WHERE rowid=old.id;
                END;
                """
            )
            try prepareContentSchema()
            try prepareJobSchema()
            try prepareDiscoverySchema()
            try prepareMediaJobSchema()
            let existing = try statement("SELECT value FROM profile")
            let old = sqlite3_step(existing) == SQLITE_ROW ? string(existing, 0) : nil
            sqlite3_finalize(existing)
            if old != profile {
                try sql("""
                    BEGIN IMMEDIATE; DELETE FROM files; DELETE FROM lexical; DELETE FROM jobs; DELETE FROM media_jobs; DELETE FROM work_queue; DELETE FROM discovery; DELETE FROM scan_directories; DELETE FROM scan_scope; DELETE FROM profile;
                    """
                )
                do { try execute("INSERT INTO profile VALUES(?)", [profile]); try sql("COMMIT;") } catch {
                    try? sql("ROLLBACK"); throw error
                }
            }
            try prepareSearchSchema()
            lexicalReader = try SemanticLexicalReader(url: url)
            vectorReader = try SemanticVectorReader(url: url)
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    func unchanged(path: String, modified: Date, bytes: Int64) throws -> Bool {
        try lock.withLock {
            let stmt =
                try statement("""
                    SELECT f.modified,f.bytes,COALESCE(j.state,'done') FROM files f LEFT JOIN jobs j ON j.path=f.path WHERE f.path=?
                    """
                )
            defer { sqlite3_finalize(stmt) }
            self.bind(stmt, [path])
            return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_double(stmt, 0) == modified.timeIntervalSince1970
                && sqlite3_column_int64(stmt, 1) == bytes &&
                (SemanticMediaPriority.of(path) != .document || self.string(
                    stmt,
                    2
                ) == "done")
        }
    }

    func replace(path: String, modified: Date, bytes: Int64, chunks: [SemanticChunk], vectors: [[Float]]) throws {
        guard chunks.count == vectors.count, vectors.allSatisfy(Self.valid) else { throw Failure.invalidVector }
        try lock.withLock {
            try self.sql("BEGIN IMMEDIATE")
            do {
                try self.execute("DELETE FROM files WHERE path=?", [path])
                try self.execute("DELETE FROM jobs WHERE path=?", [path])
                try self.execute(
                    "INSERT INTO files(path,modified,bytes) VALUES(?,?,?)",
                    [path, modified.timeIntervalSince1970, bytes]
                )
                for (chunk, vector) in zip(chunks, vectors) {
                    let data = vector.withUnsafeBytes { Data($0) }
                    try self.execute(
                        "INSERT INTO chunks(path,text,page,time,vector,search_script) VALUES(?,?,?,?,?,?)",
                        [path, chunk.text, chunk.page as Any, chunk.time as Any, data,
                         SemanticScoreCalibration.script(chunk.text)]
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
        try lock.withLock {
            try transaction {
                try execute("DELETE FROM files WHERE path=?", [path])
                try execute("DELETE FROM jobs WHERE path=?", [path])
                try execute("DELETE FROM media_jobs WHERE path=?", [path])
                try execute("DELETE FROM work_queue WHERE path=?", [path])
            }
        }
    }

    func prune(keeping paths: Set<String>, cancelled: () -> Bool) throws {
        try lock.withLock {
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
        try lock.withLock {
            try self
                .sql("""
                    DELETE FROM files; DELETE FROM jobs; DELETE FROM media_jobs; DELETE FROM work_queue; DELETE FROM discovery; DELETE FROM scan_directories; DELETE FROM scan_scope; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;
                    """
                )
        }
    }

    func counts() throws -> Counts {
        try lock.withLock {
            let stmt = try statement("""
                SELECT path FROM files WHERE EXISTS(SELECT 1 FROM chunks WHERE chunks.path=files.path)
                """)
            defer { sqlite3_finalize(stmt) }
            var result = Counts()
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                switch SemanticMediaPriority.of(self.string(stmt, 0)) {
                case .document: result.documents += 1
                case .image: result.images += 1
                case .audio: result.audio += 1
                case .video: result.videos += 1
                }
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            result.chunks = try self.count("chunks")
            return result
        }
    }

    // swiftlint:disable:next function_parameter_count
    func search(vector: [Float], text: String, query: AskSearchQuery, type: AskFileType,
                scope: AskFileScope, limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        guard let vectorReader else { throw Failure.database }
        return try vectorReader.search(vector: vector, text: text, query: query, type: type,
                                       scope: scope, limit: limit, cancelled: cancelled)
    }

    // swiftlint:disable:next function_parameter_count
    func lexicalSearch(text: String, query: AskSearchQuery, type: AskFileType, scope: AskFileScope,
                       limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        guard let lexicalReader else { throw Failure.database }
        return try lexicalReader.search(text: text, query: query, type: type, scope: scope,
                                        limit: limit, cancelled: cancelled)
    }

    static func valid(_ vector: [Float]) -> Bool {
        guard vector.count == SemanticFilePolicy.dimension, vector.allSatisfy(\.isFinite) else { return false }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(norm - 1) < 0.02
    }

    func count(_ table: String) throws -> Int {
        let stmt = try statement("SELECT count(*) FROM " + table)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func sql(_ value: String) throws {
        guard sqlite3_exec(database, value, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }

    func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw Failure.database }
        return stmt
    }

    func execute(_ sql: String, _ values: [Any]) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.database }
    }

    func bind(_ stmt: OpaquePointer, _ values: [Any]) {
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

    func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}

extension SemanticFileStore {
    func prepareSearch(cancelled: () -> Bool) throws {
        guard let vectorReader else { throw Failure.database }
        try vectorReader.prepare(cancelled: cancelled)
    }

    private func prepareContentSchema() throws {
        let columns = try statement("PRAGMA table_info(chunks)")
        var hasTime = false
        while sqlite3_step(columns) == SQLITE_ROW {
            hasTime = hasTime || string(columns, 1) == "time"
        }
        sqlite3_finalize(columns)
        if !hasTime {
            try sql("ALTER TABLE chunks ADD COLUMN time REAL")
        }
        try sql("CREATE TABLE IF NOT EXISTS discovery(path TEXT PRIMARY KEY, priority INTEGER NOT NULL);")
        try sql("CREATE INDEX IF NOT EXISTS discovery_priority ON discovery(priority,path);")
    }

    func destroy() throws {
        try lock.withLock {
            lexicalReader?.close()
            vectorReader?.close()
            guard sqlite3_close(database) == SQLITE_OK else { throw Failure.database }
            database = nil
            try Self.removeFiles(at: url)
        }
    }

    /// Also works when a corrupt database could not be opened during preparation.
    static func removeFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
