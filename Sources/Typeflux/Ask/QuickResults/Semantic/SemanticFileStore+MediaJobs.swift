import Foundation
import SQLite3

extension SemanticFileStore {
    static let mediaProvenance = "model=\(SemanticModel.sha256);projector=\(SemanticMediaModel.sha256);prompt=media-v1;sampling=audio30-video10-v1;chunk=segment-v1"

    func prepareMediaJobSchema() throws {
        try transaction {
            try sql("""
            CREATE TABLE IF NOT EXISTS media_jobs(path TEXT PRIMARY KEY,version TEXT NOT NULL,generation TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS media_segments(
                path TEXT NOT NULL REFERENCES media_jobs(path) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,kind TEXT NOT NULL,time REAL,vector BLOB NOT NULL,
                PRIMARY KEY(path,ordinal));
            """)
            try addColumn("media_jobs", name: "recipe", declaration: "TEXT NOT NULL DEFAULT ''")
            try addColumn("media_segments", name: "end_time", declaration: "REAL")
        }
    }

    func beginMediaJob(path: String, metadata: AskFileReadResponse) throws -> String {
        try lock.withLock {
            let row = try statement("SELECT generation,version,recipe FROM media_jobs WHERE path=?")
            bind(row, [path])
            let matched = sqlite3_step(row) == SQLITE_ROW && string(row, 1) == Self
                .version(metadata) && string(row, 2) == Self.mediaProvenance
            let old = matched ? string(row, 0) : nil
            sqlite3_finalize(row)
            if let old {
                try execute("""
                    UPDATE jobs SET attempts=attempts+CASE WHEN state='failed' THEN 1 ELSE 0 END,
                        state='partial',reason=NULL WHERE path=? AND generation=?
                    """, [path, old])
                return old
            }
            return try transaction {
                let generation = UUID().uuidString
                try execute("DELETE FROM media_jobs WHERE path=?", [path])
                try execute(
                    "INSERT INTO media_jobs(path,version,generation,recipe) VALUES(?,?,?,?)",
                    [path, Self.version(metadata), generation, Self.mediaProvenance]
                )
                try execute("""
                    INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,recipe) VALUES(?,?,?,'partial',?,?)
                    """,
                    [path, Self.version(metadata), generation, "{\"page\":0,\"offset\":0}", Self.mediaProvenance]
                )
                return generation
            }
        }
    }

    func hasMediaSegment(path: String, generation: String, ordinal: Int) throws -> Bool {
        try lock.withLock {
            let row =
                try statement("""
                    SELECT 1 FROM media_segments s JOIN media_jobs j ON j.path=s.path WHERE s.path=? AND j.generation=? AND ordinal=?
                    """
                )
            defer { sqlite3_finalize(row) }
            bind(row, [path, generation, ordinal])
            let step = sqlite3_step(row)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
            return step == SQLITE_ROW
        }
    }

    func saveMediaSegment(
        path: String,
        generation: String,
        ordinal: Int,
        input: SemanticMediaInput,
        vector: [Float]
    ) throws {
        guard Self.valid(vector),
              input.time.map({ $0.isFinite && $0 >= 0 }) ?? true,
              input.endTime.map({ $0.isFinite && $0 >= (input.time ?? 0) }) ?? true else { throw Failure.invalidVector }
        try lock.withLock {
            try transaction {
                try execute("""
                INSERT OR IGNORE INTO media_segments(path,ordinal,kind,time,end_time,vector)
                SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM media_jobs WHERE path=? AND generation=?)
                """, [
                    path,
                    ordinal,
                    input.kind.rawValue,
                    input.time as Any,
                    input.endTime as Any,
                    vector.withUnsafeBytes { Data($0) },
                    path,
                    generation
                ])
                try execute("UPDATE jobs SET state='partial',cursor=?,reason=NULL WHERE path=? AND generation=?",
                            ["{\"page\":0,\"offset\":\(ordinal + 1)}", path, generation])
            }
        }
    }

    func commitMediaJob(path: String, generation: String, metadata: AskFileReadResponse, segments: Int) throws -> Bool {
        try lock.withLock {
            let row =
                try statement("""
                    SELECT count(*) FROM media_segments s JOIN media_jobs j ON j.path=s.path WHERE s.path=? AND j.generation=?
                    """
                )
            defer { sqlite3_finalize(row) }
            bind(row, [path, generation])
            guard sqlite3_step(row) == SQLITE_ROW, segments > 0, sqlite3_column_int64(row, 0) == segments,
                  let date = metadata.modified, let bytes = metadata.fileSize else { return false }
            return try transaction {
                try execute("DELETE FROM files WHERE path=?", [path])
                try execute(
                    "UPDATE jobs SET state='done',extracted=1,reason=NULL WHERE path=? AND generation=?",
                    [path, generation]
                )
                try execute("INSERT INTO files(path,modified,bytes,version) VALUES(?,?,?,?)",
                            [path, date.timeIntervalSince1970, bytes, metadata.version ?? ""])
                try execute("""
                INSERT INTO chunks(path,text,time,end_time,vector,generation,modality,segment_kind,provenance)
                SELECT path,'',time,end_time,vector,?,
                    CASE WHEN kind='audio' THEN 'audio' ELSE ? END,
                    CASE WHEN kind='audio' THEN 'audio-window' ELSE ? END,?
                    FROM media_segments WHERE path=? ORDER BY ordinal
                """, [generation, SemanticMediaPriority.of(path) == .video ? "video" : "image",
                      SemanticMediaPriority.of(path) == .video ? "video-frame" : "image", Self.mediaProvenance, path])
                try execute("DELETE FROM media_jobs WHERE path=?", [path])
                return true
            }
        }
    }

    func mediaUnchanged(path: String, metadata: AskFileReadResponse) throws -> Bool {
        try lock.withLock {
            let row = try statement("""
            SELECT version FROM files WHERE path=? AND NOT EXISTS(
                SELECT 1 FROM chunks c WHERE c.path=files.path AND (c.provenance IS NULL OR c.provenance<>?))
            """)
            defer { sqlite3_finalize(row) }
            bind(row, [path, Self.mediaProvenance])
            if sqlite3_step(row) != SQLITE_ROW {
                return false
            }
            if let version = metadata.version {
                return string(row, 0) == version
            }
            // Deterministic readers without filesystem identities retain the legacy metadata contract.
            let legacy = try statement("SELECT modified,bytes FROM files WHERE path=?")
            defer { sqlite3_finalize(legacy) }
            bind(legacy, [path])
            return sqlite3_step(legacy) == SQLITE_ROW
                && sqlite3_column_double(legacy, 0) == metadata.modified?.timeIntervalSince1970
                && sqlite3_column_int64(legacy, 1) == metadata.fileSize
        }
    }
}
