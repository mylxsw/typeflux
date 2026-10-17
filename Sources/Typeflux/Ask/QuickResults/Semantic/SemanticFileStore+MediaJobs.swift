import Foundation
import SQLite3

extension SemanticFileStore {
    static let mediaProvenance = "model=\(SemanticModel.sha256);projector=\(SemanticMediaModel.sha256);prompt=media-v1;sampling=audio30-video10-v1;chunk=segment-v1"

    static let audioProvenance = mediaProvenance + ";" + SemanticAudioWindows.recipe
    static let videoProvenance = mediaProvenance + ";" + SemanticVideoFrames.recipe

    static func mediaVectorProvenance(_ path: String, kind: SemanticMediaInput.Kind) -> String {
        if SemanticMediaPriority.of(path) == .audio { return audioProvenance }
        return SemanticMediaPriority.of(path) == .video && kind == .image ? videoProvenance : mediaProvenance
    }

    func prepareMediaJobSchema() throws {
        try transaction {
            try sql("""
            CREATE TABLE IF NOT EXISTS media_jobs(path TEXT PRIMARY KEY,version TEXT NOT NULL,generation TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS media_segments(
                path TEXT NOT NULL REFERENCES media_jobs(path) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,kind TEXT NOT NULL,time REAL,vector BLOB NOT NULL,
                PRIMARY KEY(path,ordinal));
            """)
            try sql("""
            CREATE TABLE IF NOT EXISTS media_text(
                path TEXT NOT NULL REFERENCES media_jobs(path) ON DELETE CASCADE,
                start_offset INTEGER NOT NULL,end_offset INTEGER NOT NULL,text TEXT NOT NULL,vector BLOB NOT NULL,
                PRIMARY KEY(path,start_offset));
            """)
            try execute("""
            INSERT OR IGNORE INTO work_queue(path,priority)
            SELECT j.path,1 FROM files j LEFT JOIN jobs job ON job.path=j.path
            WHERE COALESCE(job.recipe,'')<>? AND EXISTS(
                SELECT 1 FROM chunks c WHERE c.path=j.path AND c.modality='image')
            AND (lower(substr(j.path,-4)) IN ('.png','.jpg') OR lower(substr(j.path,-5))='.jpeg')
            """, [Self.mediaRecipe("upgrade.png")])
            try sql("CREATE INDEX IF NOT EXISTS media_generation ON media_jobs(generation)")
            try addColumn("media_jobs", name: "recipe", declaration: "TEXT NOT NULL DEFAULT ''")
            try addColumn("media_segments", name: "end_time", declaration: "REAL")
            try addColumn("media_jobs", name: "video_progress", declaration: "BLOB")
            try addColumn("media_jobs", name: "audio_next", declaration: "REAL")
            try addColumn("media_jobs", name: "audio_covered", declaration: "REAL")
            try queueVideoRecipeUpgrade()
            let extensions = SemanticMediaPriority.audioExtensions.sorted()
            let suffixes = extensions.map { _ in "lower(substr(c.path,-?))=?" }.joined(separator: " OR ")
            try execute("""
            INSERT OR IGNORE INTO work_queue(path,priority)
            SELECT c.path,2 FROM (SELECT path FROM files UNION SELECT path FROM jobs) c
            LEFT JOIN jobs j ON j.path=c.path WHERE COALESCE(j.recipe,'')<>? AND (\(suffixes))
            """, [Self.audioProvenance] + extensions.flatMap { [$0.count + 1, "." + $0] as [Any] })
        }
    }

    func beginMediaJob(path: String, metadata: AskFileReadResponse) throws -> String {
        try lock.withLock {
            let row = try statement("SELECT generation,version,recipe FROM media_jobs WHERE path=?")
            bind(row, [path])
            let matched = sqlite3_step(row) == SQLITE_ROW && string(row, 1) == Self
                .version(metadata) && string(row, 2) == Self.mediaRecipe(path)
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
                    [path, Self.version(metadata), generation, Self.mediaRecipe(path)]
                )
                try execute("""
                            INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,recipe) VALUES(?,?,?,'partial',?,?)
                            """,
                            [
                                path,
                                Self.version(metadata),
                                generation,
                                "{\"page\":0,\"offset\":0}",
                                Self.mediaRecipe(path)
                            ])
                if SemanticMediaPriority.of(path) == .image, metadata.version != nil {
                    // Reuse only a verified same-version visual input with the exact model/projector recipe.
                    try execute("""
                    INSERT INTO media_segments(path,ordinal,kind,vector)
                    SELECT c.path,0,'image',c.vector FROM chunks c JOIN files f ON f.path=c.path
                    WHERE c.path=? AND f.version=? AND c.modality='image' AND c.provenance=?
                    AND length(c.vector)=? LIMIT 1
                    """, [path, metadata.version ?? "", Self.mediaProvenance, SemanticFilePolicy.dimension * 4])
                }
                return generation
            }
        }
    }

    func hasMediaSegment(path: String, generation: String, ordinal: Int) throws -> Bool {
        try lock.withLock {
            let row =
                try statement("""
                SELECT 1 FROM media_segments s JOIN media_jobs j ON j.path=s.path WHERE s.path=? AND j.generation=? AND ordinal=?
                """)
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
        vector: [Float],
        audioProgress: SemanticAudioProgress? = nil,
        videoProgress: SemanticVideoProgress? = nil
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
                if let videoProgress {
                    try saveVideoProgressLocked(path: path, generation: generation, progress: videoProgress)
                }
                if let audioProgress {
                    try saveAudioProgressLocked(path: path, generation: generation, progress: audioProgress)
                }
                try execute("UPDATE jobs SET state='partial',cursor=?,reason=NULL WHERE path=? AND generation=?",
                            ["{\"page\":0,\"offset\":\(ordinal + 1)}", path, generation])
            }
        }
    }

    func commitMediaJob(path: String, generation: String, metadata: AskFileReadResponse, segments: Int) throws -> Bool {
        try lock.withLock {
            let row =
                try statement("""
                SELECT count(s.ordinal),COALESCE(MAX(j.audio_covered),0) FROM media_jobs j
                LEFT JOIN media_segments s ON j.path=s.path WHERE j.path=? AND j.generation=?
                """)
            defer { sqlite3_finalize(row) }
            bind(row, [path, generation])
            guard sqlite3_step(row) == SQLITE_ROW, segments >= 0, sqlite3_column_int64(row, 0) == segments,
                  segments > 0 || (SemanticMediaPriority.of(path) == .audio && sqlite3_column_double(row, 1) > 0),
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
                    CASE WHEN kind='audio' THEN 'audio-window' ELSE ? END,
                    CASE WHEN kind='audio' THEN ? ELSE ? END
                    FROM media_segments WHERE path=? ORDER BY ordinal
                """, [generation, SemanticMediaPriority.of(path) == .video ? "video" : "image",
                      SemanticMediaPriority.of(path) == .video ? "video-frame" : "image",
                      Self.mediaVectorProvenance(path, kind: .audio),
                      Self.mediaVectorProvenance(path, kind: .image), path])
                try recordLocked(.vectorsPublished, count: segments)
                let text =
                    try statement(
                        "SELECT text,start_offset,end_offset,vector FROM media_text WHERE path=? ORDER BY start_offset"
                    )
                defer { sqlite3_finalize(text) }; bind(text, [path])
                while sqlite3_step(text) == SQLITE_ROW {
                    try execute("""
                    INSERT INTO chunks(path,text,vector,generation,start_offset,end_offset,modality,segment_kind,provenance)
                    VALUES(?,?,?,?,?,?,'text','image-ocr',?)
                    """, [path, string(text, 0), Data(bytes: sqlite3_column_blob(text, 3)!,
                                                      count: Int(sqlite3_column_bytes(text, 3))), generation,
                          sqlite3_column_int64(text, 1), sqlite3_column_int64(text, 2), Self.imageRecipe])
                    try writeLexical(sqlite3_last_insert_rowid(database), text: string(text, 0))
                }
                let imageNeedsText = SemanticMediaPriority.of(path) == .image
                    && Self.mediaRecipe(path) != Self.mediaProvenance
                try execute("""
                UPDATE jobs SET recipe=?,reason=CASE WHEN ? AND NOT EXISTS(
                    SELECT 1 FROM media_text WHERE path=?) THEN 'image-no-text' ELSE NULL END WHERE path=?
                """, [Self.mediaRecipe(path), imageNeedsText ? 1 : 0, path, path])
                if segments == 0 {
                    try execute("UPDATE jobs SET reason='audio-silent' WHERE path=?", [path])
                }
                try execute("DELETE FROM media_jobs WHERE path=?", [path])
                return true
            }
        }
    }

    func mediaUnchanged(path: String, metadata: AskFileReadResponse) throws -> Bool {
        try lock.withLock {
            let row = try statement("""
            SELECT version FROM files WHERE path=? AND NOT EXISTS(
                SELECT 1 FROM chunks c WHERE c.path=files.path AND (c.provenance IS NULL OR c.provenance NOT IN (?,?,?)))
                AND EXISTS(SELECT 1 FROM jobs j WHERE j.path=files.path AND j.recipe=? AND j.state='done')
            """)
            defer { sqlite3_finalize(row) }
            bind(row, [path, Self.mediaVectorProvenance(path, kind: .image),
                       Self.imageRecipe, Self.mediaVectorProvenance(path, kind: .audio), Self.mediaRecipe(path)])
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

extension SemanticFileStore {
    func mediaCursor(path: String, generation: String) throws -> SemanticMediaCursor {
        try lock.withLock {
            let row = try statement("""
            SELECT COUNT(*),COALESCE(MAX(ordinal)+1,0),COALESCE(SUM(kind='image'),0),COALESCE(MAX(CASE WHEN kind='audio' THEN end_time ELSE 0 END),0),COALESCE(SUM(kind='audio' AND end_time IS NULL),0)
            FROM media_segments s JOIN media_jobs j ON j.path=s.path WHERE s.path=? AND j.generation=?
            """)
            defer { sqlite3_finalize(row) }; bind(row, [path, generation])
            guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.database }
            let count = Int(sqlite3_column_int64(row, 0)), next = Int(sqlite3_column_int64(row, 1))
            guard count == next else { throw Failure.database }
            if sqlite3_column_int64(row, 4) > 0 {
                return .init()
            }
            let images = Int(sqlite3_column_int64(row, 2))
            let checkpoint = try statement(
                "SELECT audio_next,audio_covered FROM media_jobs WHERE path=? AND generation=?"
            )
            defer { sqlite3_finalize(checkpoint) }; bind(checkpoint, [path, generation])
            let saved = sqlite3_step(checkpoint) == SQLITE_ROW && sqlite3_column_type(checkpoint, 0) != SQLITE_NULL
            return .init(
                nextOrdinal: next,
                videoFrames: images,
                imageDone: images > 0,
                audioUntil: saved ? sqlite3_column_double(checkpoint, 0) : sqlite3_column_double(row, 3),
                audioCoveredUntil: saved ? sqlite3_column_double(checkpoint, 1) : sqlite3_column_double(row, 3),
                videoProgress: try videoProgressLocked(path: path, generation: generation)
            )
        }
    }
}

extension SemanticFileStore {
    func removeOrphanMediaCache(cancelled: () -> Bool) throws {
        let cache = url.deletingLastPathComponent().appendingPathComponent(".typeflux-media-cache")
        guard let walk = FileManager.default.enumerator(
            at: cache,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        var inspected = 0
        for case let folder as URL in walk {
            try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
            let generation = folder.lastPathComponent
            guard UUID(uuidString: generation) != nil else { continue }
            let keep = try lock.withLock {
                let row = try statement("SELECT 1 FROM media_jobs WHERE generation=? LIMIT 1")
                defer { sqlite3_finalize(row) }; bind(row, [generation])
                let step = sqlite3_step(row)
                guard step == SQLITE_ROW || step == SQLITE_DONE else { throw Failure.database }
                return step == SQLITE_ROW
            }
            if !keep {
                try FileManager.default.removeItem(at: folder); inspected += 1
            }
            if inspected >= 16 {
                break
            }
        }
    }
}
