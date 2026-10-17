import Foundation

extension SemanticFileStore {
    /// A silent window advances the same private job without inventing an encoded segment.
    /// Called inside the segment transaction for non-silent windows, so resume cannot drift.
    func saveAudioProgress(path: String, generation: String, progress: SemanticAudioProgress) throws {
        try lock.withLock { try saveAudioProgressLocked(path: path, generation: generation, progress: progress) }
    }

    func saveAudioProgressLocked(path: String, generation: String, progress: SemanticAudioProgress) throws {
        guard progress.next.isFinite, progress.covered.isFinite,
              progress.next >= 0, progress.covered >= progress.next else { throw Failure.database }
        try execute("""
            UPDATE media_jobs SET audio_next=MAX(COALESCE(audio_next,0),?),
                audio_covered=MAX(COALESCE(audio_covered,0),?) WHERE path=? AND generation=?
            """, [progress.next, progress.covered, path, generation])
    }
}
