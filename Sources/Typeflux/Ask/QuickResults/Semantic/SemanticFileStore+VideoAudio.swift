import Foundation
import SQLite3

extension SemanticFileStore {
    /// Preserve the frame checkpoint when only the embedded-audio recipe changes.
    func upgradeVideoAudioJob(path: String, metadata: AskFileReadResponse) throws {
        guard SemanticMediaPriority.of(path) == .video else { return }
        let row = try statement("SELECT generation FROM media_jobs WHERE path=? AND version=? AND recipe=?")
        defer { sqlite3_finalize(row) }
        bind(row, [path, Self.version(metadata), Self.videoProvenance])
        guard sqlite3_step(row) == SQLITE_ROW else { return }
        let previous = string(row, 0), generation = UUID().uuidString
        try transaction {
            try execute("DELETE FROM media_segments WHERE path=? AND kind='audio'", [path])
            try execute("UPDATE media_jobs SET recipe=?,generation=?,audio_next=NULL,audio_covered=NULL WHERE path=?",
                        [Self.videoAudioRecipe, generation, path])
            try execute("UPDATE jobs SET recipe=?,generation=? WHERE path=? AND generation=?",
                        [Self.videoAudioRecipe, generation, path, previous])
        }
    }

    /// Published chunks have already passed final version checks. Their frame recipe is unchanged.
    func reusePublishedVideoFrames(path: String, metadata: AskFileReadResponse, generation: String) throws {
        guard SemanticMediaPriority.of(path) == .video, let version = metadata.version else { return }
        try execute("""
        INSERT INTO media_segments(path,ordinal,kind,time,end_time,vector)
        SELECT c.path,ROW_NUMBER() OVER (ORDER BY c.id)-1,'image',c.time,c.end_time,c.vector
        FROM chunks c JOIN files f ON f.path=c.path
        WHERE c.path=? AND f.version=? AND c.modality='video' AND c.segment_kind='video-frame'
            AND c.provenance=? AND length(c.vector)=?
        """, [path, version, Self.videoProvenance, SemanticFilePolicy.dimension * 4])
        let row = try statement("SELECT MAX(time) FROM media_segments WHERE path=? AND kind='image'")
        defer { sqlite3_finalize(row) }; bind(row, [path])
        guard sqlite3_step(row) == SQLITE_ROW, sqlite3_column_type(row, 0) != SQLITE_NULL else { return }
        let actual = sqlite3_column_double(row, 0)
        try saveVideoProgressLocked(path: path, generation: generation,
            progress: .init(next: actual, actual: actual, reference: Data(repeating: 0, count: 1024), complete: true))
    }
}
