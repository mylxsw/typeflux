import Foundation
import SQLite3

extension SemanticFileStore {
    func queueVideoRecipeUpgrade() throws {
        let extensions = SemanticMediaPriority.videoExtensions.sorted()
        let suffixes = extensions.map { _ in "lower(substr(c.path,-?))=?" }.joined(separator: " OR ")
        try execute("""
        INSERT OR IGNORE INTO work_queue(path,priority)
        SELECT c.path,3 FROM (SELECT path FROM files UNION SELECT path FROM jobs) c
        LEFT JOIN jobs j ON j.path=c.path WHERE COALESCE(j.recipe,'')<>? AND (\(suffixes))
        """, [Self.videoAudioRecipe] + extensions.flatMap { [$0.count + 1, "." + $0] as [Any] })
    }

    func saveVideoProgress(path: String, generation: String, progress: SemanticVideoProgress) throws {
        try lock.withLock { try saveVideoProgressLocked(path: path, generation: generation, progress: progress) }
    }

    /// Shares the vector transaction for retained frames; duplicate frames advance without inference.
    func saveVideoProgressLocked(path: String, generation: String, progress: SemanticVideoProgress) throws {
        guard progress.valid else { throw Failure.database }
        if let previous = try videoProgressLocked(path: path, generation: generation) {
            guard progress.next >= previous.next, !previous.complete || progress == previous else {
                throw Failure.database
            }
        }
        try execute("""
        UPDATE media_jobs SET video_progress=? WHERE path=? AND generation=?
        """, [JSONEncoder().encode(progress), path, generation])
    }

    func videoProgressLocked(path: String, generation: String) throws -> SemanticVideoProgress? {
        let row = try statement("SELECT video_progress FROM media_jobs WHERE path=? AND generation=?")
        defer { sqlite3_finalize(row) }; bind(row, [path, generation])
        guard sqlite3_step(row) == SQLITE_ROW, let bytes = sqlite3_column_blob(row, 0) else { return nil }
        let value = try JSONDecoder().decode(SemanticVideoProgress.self,
                                             from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 0))))
        guard value.valid else { throw Failure.database }
        return value
    }
}
