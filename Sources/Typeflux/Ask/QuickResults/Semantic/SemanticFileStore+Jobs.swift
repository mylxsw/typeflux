import Foundation
import SQLite3

extension SemanticFileStore {
    enum JobState: String { case pending, partial, done, skipped, failed }
    struct Job {
        var path: String
        var version: String
        var generation: String
        var state: JobState
        var cursor: SemanticContentCursor
        var extracted: Bool
        var attempts: Int
        var reason: String?
        var recipe: String = ""
    }

    struct VectorWork {
        var id: Int64
        var text: String
    }

    /// Additive, transactional migration retains compatible vectors. Legacy documents are revisited once
    /// because an old "done" row cannot prove that its tail was extracted.
    func prepareJobSchema() throws {
        try transaction {
            try addColumn("files", name: "version", declaration: "TEXT NOT NULL DEFAULT ''")
            for (name, type) in [("generation", "TEXT"), ("start_offset", "INTEGER"), ("end_offset", "INTEGER"),
                                 ("end_time", "REAL"), ("modality", "TEXT"), ("segment_kind", "TEXT"), (
                                     "provenance",
                                     "TEXT"
                                 )] {
                try addColumn("chunks", name: name, declaration: type)
            }
            try sql("""
            CREATE TABLE IF NOT EXISTS jobs(
                path TEXT PRIMARY KEY,version TEXT NOT NULL,generation TEXT NOT NULL,
                state TEXT NOT NULL,cursor TEXT NOT NULL,extracted INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0,reason TEXT);
            CREATE TABLE IF NOT EXISTS work_queue(
                turn INTEGER PRIMARY KEY AUTOINCREMENT,path TEXT NOT NULL UNIQUE,priority INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS work_priority ON work_queue(priority,turn);
            CREATE INDEX IF NOT EXISTS chunk_generation ON chunks(path,generation);
            """)
            try addColumn("jobs", name: "recipe", declaration: "TEXT NOT NULL DEFAULT ''")
            try addColumn("jobs", name: "processing_seconds", declaration: "REAL")
            try addColumn("jobs", name: "completed_at", declaration: "REAL")
            // A completed discovery must not hide PDFs whose previously blank pages now support OCR.
            try execute("""
            INSERT OR IGNORE INTO work_queue(path,priority)
            SELECT path,0 FROM jobs WHERE recipe=? AND lower(substr(path,-4))='.pdf'
            """, [Self.documentProvenance])
        }
    }

    func addColumn(_ table: String, name: String, declaration: String) throws {
        let row = try statement("PRAGMA table_info(\(table))")
        var found = false
        while sqlite3_step(row) == SQLITE_ROW {
            found = found || string(row, 1) == name
        }
        sqlite3_finalize(row)
        if !found {
            try sql("ALTER TABLE \(table) ADD COLUMN \(name) \(declaration)")
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try sql("BEGIN IMMEDIATE")
        do { let value = try body(); try sql("COMMIT"); return value } catch {
            try? sql("ROLLBACK"); throw error
        }
    }

    func job(_ path: String) throws -> Job? {
        try lock.withLock { try readJob(path) }
    }

    private func readJob(_ path: String) throws -> Job? {
        let row =
            try statement(
                "SELECT version,generation,state,cursor,extracted,attempts,reason,recipe FROM jobs WHERE path=?"
            )
        defer { sqlite3_finalize(row) }
        bind(row, [path])
        let step = sqlite3_step(row)
        if step == SQLITE_DONE {
            return nil
        }
        guard step == SQLITE_ROW, let state = JobState(rawValue: string(row, 2)),
              let data = string(row, 3).data(using: .utf8),
              let cursor = try? JSONDecoder().decode(SemanticContentCursor.self, from: data)
        else { throw Failure.database }
        return Job(path: path, version: string(row, 0), generation: string(row, 1), state: state,
                   cursor: cursor, extracted: sqlite3_column_int(row, 4) != 0,
                   attempts: Int(sqlite3_column_int(row, 5)),
                   reason: sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : string(row, 6), recipe: string(row, 7))
    }

    func prepareDocument(path: String, metadata: AskFileReadResponse) throws -> Job {
        guard let modified = metadata.modified, let bytes = metadata.fileSize else { throw Failure.database }
        let version = Self.version(metadata)
        let recipe = Self.documentRecipe(path)
        return try lock.withLock {
            if var existing = try readJob(path), existing.version == version,
               existing.recipe == recipe {
                if existing.state == .failed {
                    try execute("UPDATE jobs SET state='partial',reason=NULL,attempts=attempts+1 WHERE path=?", [path])
                    existing.state = .partial; existing.reason = nil; existing.attempts += 1
                    try recordLocked(.retries)
                }
                return existing
            }
            let generation = UUID().uuidString
            return try transaction {
                let existing = try readJob(path)
                let upgradePDF = (path as NSString).pathExtension.lowercased() == "pdf"
                    && existing?.recipe == Self.documentProvenance
                    && existing?.version == version
                if !upgradePDF {
                    try execute("DELETE FROM files WHERE path=?", [path])
                }
                // Preserve compatible PDF vectors until their unchanged chunks are adopted by the new job.
                try execute("INSERT OR IGNORE INTO files(path,modified,bytes,version) VALUES(?,?,?,?)",
                            [path, modified.timeIntervalSince1970, bytes, metadata.version ?? ""])
                try execute("""
                            INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,recipe) VALUES(?,?,?,'pending',?,?)
                            """,
                            [path, version, generation, "{\"page\":0,\"offset\":0}", recipe])
                return Job(path: path, version: version, generation: generation, state: .pending,
                           cursor: .init(), extracted: false, attempts: 0, recipe: recipe)
            }
        }
    }

    static func version(_ metadata: AskFileReadResponse) -> String {
        metadata.version ?? "legacy:\(metadata.modified?.timeIntervalSince1970 ?? 0):\(metadata.fileSize ?? -1)"
    }

    static let documentProvenance = "model=\(SemanticModel.sha256);projector=none;prompt=title-text-v1;sampling=none;chunk=utf8-scalar1200-overlap40-batch32k-v2"

    static func documentRecipe(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": return documentProvenance + ";" + SemanticPDFText.recipe
        case "docx": return documentProvenance + ";" + SemanticWordText.recipe
        default: return documentProvenance
        }
    }

    /// Only a same-version, same-input PDF upgrade may reuse an old vector. No model-space change occurs.
    private func adoptPDFChunk(_ chunk: SemanticChunk, job: Job) throws -> Bool {
        guard (job.path as NSString).pathExtension.lowercased() == "pdf",
              job.recipe == Self.documentRecipe(job.path), job.recipe != Self.documentProvenance else { return false }
        let row = try statement("""
        SELECT id FROM chunks WHERE path=? AND generation<>? AND provenance=? AND text=?
        AND page=? AND start_offset=? AND end_offset=? AND length(vector)=? LIMIT 1
        """)
        defer { sqlite3_finalize(row) }
        bind(row, [job.path, job.generation, Self.documentProvenance, chunk.text, chunk.page as Any,
                   chunk.startOffset as Any, chunk.endOffset as Any, SemanticFilePolicy.dimension * 4])
        let step = sqlite3_step(row)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
        guard step == SQLITE_ROW else { return false }
        try execute("UPDATE chunks SET generation=?,provenance=?,segment_kind=? WHERE id=?",
                    [job.generation, job.recipe, chunk.segmentKind ?? "pdf-text", sqlite3_column_int64(row, 0)])
        try recordLocked(.vectorReusedSegments)
        return true
    }

    /// FTS and the next extraction checkpoint commit together. Empty vectors mean pending encoding;
    /// vector readers already reject any payload that is not 768 floats.
    @discardableResult
    func publish(_ chunks: [SemanticChunk], next: SemanticContentCursor?, job: Job) throws -> Bool {
        try lock.withLock {
            guard let current = try readJob(job.path), current.generation == job.generation,
                  current.cursor == job.cursor, !current.extracted else { return false }
            return try transaction {
                var published = 0
                for chunk in chunks {
                    if try adoptPDFChunk(chunk, job: job) { continue }
                    try execute("""
                    INSERT INTO chunks(path,text,page,vector,generation,start_offset,end_offset,modality,segment_kind,provenance,search_script)
                    VALUES(?,?,?,X'',?,?,?,'text',?,?,?)
                    """, [job.path, chunk.text, chunk.page as Any, job.generation,
                          chunk.startOffset as Any, chunk.endOffset as Any,
                          chunk.segmentKind ?? (chunk.page == nil ? "text" : "pdf-text"), job.recipe,
                          SemanticScoreCalibration.script(chunk.text)])
                    try writeLexical(sqlite3_last_insert_rowid(database), text: chunk.text)
                    published += 1
                }
                try recordLocked(.ftsChunks, count: published)
                let data = try JSONEncoder().encode(next ?? job.cursor)
                try execute("UPDATE jobs SET cursor=?,extracted=?,state='partial',reason=NULL WHERE path=?",
                            [String(data: data, encoding: .utf8) ?? "", next == nil ? 1 : 0, job.path])
                return true
            }
        }
    }

    func vectorWork(_ job: Job) throws -> [VectorWork] {
        try lock.withLock {
            let row =
                try statement(
                    """
                    SELECT c.id,c.text FROM vector_pending p JOIN chunks c ON c.id=p.id
                    WHERE p.path=? AND p.generation=? ORDER BY p.id LIMIT 8
                    """
                )
            defer { sqlite3_finalize(row) }
            bind(row, [job.path, job.generation])
            var values: [VectorWork] = []
            var step = sqlite3_step(row)
            while step == SQLITE_ROW {
                values.append(.init(id: sqlite3_column_int64(row, 0), text: string(row, 1)))
                step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            return values
        }
    }

    @discardableResult
    func publishVectors(_ vectors: [[Float]], work: [VectorWork], job: Job) throws -> Bool {
        guard vectors.count == work.count, vectors.allSatisfy(Self.valid) else { throw Failure.invalidVector }
        return try lock.withLock {
            guard try readJob(job.path)?.generation == job.generation else { return false }
            return try transaction {
                for (item, vector) in zip(work, vectors) {
                    try execute(
                        "UPDATE chunks SET vector=? WHERE id=? AND path=? AND generation=? AND length(vector)=0",
                        [vector.withUnsafeBytes { Data($0) }, item.id, job.path, job.generation]
                    )
                    try recordLocked(.vectorsPublished, count: Int(sqlite3_changes(database)))
                }
                return true
            }
        }
    }

    func finishDocument(_ job: Job) throws -> JobState {
        try lock.withLock {
            guard let current = try readJob(job.path), current.generation == job.generation else { return .skipped }
            guard current.extracted else { return .partial }
            let row = try statement("""
            SELECT EXISTS(SELECT 1 FROM chunks WHERE path=? AND generation=? LIMIT 1),
                EXISTS(SELECT 1 FROM vector_pending WHERE path=? AND generation=? LIMIT 1)
            """)
            defer { sqlite3_finalize(row) }
            bind(row, [job.path, job.generation, job.path, job.generation])
            guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.database }
            guard sqlite3_column_int64(row, 1) == 0 else { return .partial }
            let empty = sqlite3_column_int64(row, 0) == 0
            try transaction {
                // Remove old-only chunks only after the complete replacement was extracted and encoded.
                try execute("DELETE FROM chunks WHERE path=? AND generation<>?", [job.path, job.generation])
                try execute("UPDATE jobs SET state=?,reason=? WHERE path=?",
                            [empty ? "skipped" : "done", empty ? "empty-or-no-text" as Any : NSNull(), job.path])
                if empty {
                    try execute("DELETE FROM files WHERE path=?", [job.path])
                }
            }
            return empty ? .skipped : .done
        }
    }

    /// Reasons are fixed codes, never exception text, paths or document contents.
    func failJob(_ path: String, reason: String) throws {
        try lock.withLock {
            try execute("UPDATE jobs SET state='failed',reason=? WHERE path=?", [reason, path])
            try recordLocked(.failures)
        }
    }

    func skipUnavailable(_ path: String, reason: String) throws {
        try lock.withLock {
            try transaction {
                try execute("DELETE FROM files WHERE path=?", [path])
                try execute("DELETE FROM media_jobs WHERE path=?", [path])
                try execute("""
                            INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,reason) VALUES(?,'',?,'skipped',?,?)
                            """,
                            [path, UUID().uuidString, "{\"page\":0,\"offset\":0}", reason])
            }
        }
    }

    func enqueue(_ entries: [(String, SemanticMediaPriority)]) throws {
        try lock.withLock {
            try transaction {
                for (path, priority) in entries {
                    try execute(
                        "INSERT OR IGNORE INTO work_queue(path,priority) VALUES(?,?)",
                        [path, priority.rawValue]
                    )
                }
            }
        }
    }

    func nextWork(_ priority: SemanticMediaPriority) throws -> String? {
        try lock.withLock {
            let row = try statement("""
            SELECT w.path FROM work_queue w WHERE priority=?
            AND (w.path IN (SELECT path FROM discovery) OR NOT EXISTS(
                SELECT 1 FROM scan_directories d WHERE d.state<>'done'
                AND (d.path='/' OR w.path=d.path OR substr(w.path,1,length(d.path)+1)=d.path||'/')))
            ORDER BY turn LIMIT 1
            """)
            defer { sqlite3_finalize(row) }
            bind(row, [priority.rawValue])
            let step = sqlite3_step(row)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
            return step == SQLITE_ROW ? string(row, 0) : nil
        }
    }

    func completeWork(_ path: String, more: Bool, elapsed: TimeInterval = 0) throws {
        try lock.withLock {
            try transaction {
                try execute("""
                UPDATE jobs SET processing_seconds=COALESCE(processing_seconds,0)+?,
                    completed_at=CASE WHEN ? THEN NULL ELSE ? END WHERE path=?
                """, [max(0, elapsed), more ? 1 : 0, Date().timeIntervalSince1970, path])
                if more {
                    try execute(
                        "UPDATE work_queue SET turn=(SELECT COALESCE(max(turn),0)+1 FROM work_queue) WHERE path=?",
                        [path]
                    )
                } else {
                    try execute("DELETE FROM work_queue WHERE path=?", [path])
                }
            }
        }
    }

    func recordInterruptedWork(_ path: String, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        try? lock.withLock {
            try execute("UPDATE jobs SET processing_seconds=COALESCE(processing_seconds,0)+? WHERE path=?",
                        [elapsed, path])
        }
    }
}
