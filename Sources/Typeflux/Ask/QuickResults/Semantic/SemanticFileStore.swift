import Accelerate
import Foundation
import SQLite3

private let semanticTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A separate WAL database. A file, its chunks, lexical terms and vectors commit together.
/// Serialized by the lock; no main-actor disk I/O and no shared filename-index state.
final class SemanticFileStore: @unchecked Sendable {
    enum Failure: Error { case database, invalidVector, limit }
    private let lock = NSLock()
    private var database: OpaquePointer?
    let url: URL
    static let maximumRows = 100_000

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
                guard try self.count("chunks") + chunks.count <= Self.maximumRows else { throw Failure.limit }
                try self.execute("INSERT INTO files VALUES(?,?,?)", [path, modified.timeIntervalSince1970, bytes])
                for (chunk, vector) in zip(chunks, vectors) {
                    let data = vector.withUnsafeBytes { Data($0) }
                    try self.execute(
                        "INSERT INTO chunks(path,text,page,vector) VALUES(?,?,?,?)",
                        [path, chunk.text, chunk.page as Any, data]
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
            let terms = Array(Set(SemanticFilePolicy.terms(text).split(separator: " ").map(String.init))).sorted()
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
            let stmt =
                try statement(
                    "SELECT c.id,c.path,c.text,c.page,c.vector,f.modified FROM chunks c JOIN files f ON f.path=c.path"
                )
            defer { sqlite3_finalize(stmt) }
            var best: [AskFileHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if cancelled() {
                    throw CancellationError()
                }
                let path = self.string(stmt, 1), ext = (path as NSString).pathExtension.lowercased()
                guard scope.includes(path, isDirectory: false), SemanticFilePolicy.allows(path),
                      type.matches(kind: .file, extension: ext),
                      query.fileExtension == nil || query.fileExtension == ext else { continue }
                if let folder = query.folder {
                    let place = AskSearchText.normalize((path as NSString).deletingLastPathComponent)
                    guard AskFileIndexState.contains(place, folder) else { continue }
                }
                guard sqlite3_column_bytes(stmt, 4) == SemanticFilePolicy.dimension * 4,
                      let raw = sqlite3_column_blob(stmt, 4) else { continue }
                let stored = Array(UnsafeBufferPointer(
                    start: raw.assumingMemoryBound(to: Float.self),
                    count: SemanticFilePolicy.dimension
                ))
                let cosine = vector
                    .withUnsafeBufferPointer { queryValues in stored.withUnsafeBufferPointer { storedValues in
                        Double(cblas_sdot(
                            Int32(vector.count),
                            queryValues.baseAddress!,
                            1,
                            storedValues.baseAddress!,
                            1
                        ))
                    } }
                let lexicalMatch = lexical.contains(sqlite3_column_int64(stmt, 0))
                guard cosine.isFinite, cosine >= 0.35 || lexicalMatch else { continue }
                let score = max(0, cosine) * 0.7 + (lexicalMatch ? 0.18 : 0)
                let page = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
                let hit = AskFileHit(path: path, name: (path as NSString).lastPathComponent, kind: .file,
                                     modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                                     score: score,
                                     evidence: .init(text: String(self.string(stmt, 2).prefix(180)), page: page))
                if let existing = best.firstIndex(where: { $0.path == path }) {
                    if best[existing].score >= score {
                        continue
                    }
                    best.remove(at: existing)
                }
                best.append(hit)
                best.sort { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
                if best.count > min(100, limit) {
                    best.removeLast()
                }
            }
            return best
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
