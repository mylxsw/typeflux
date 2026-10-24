import Foundation

/// Keeps progress responsive while limiting copy-on-write of the growing index tables.
struct AskFileBuildPublication {
    enum Update { case snapshot, progress, none }
    private var lastSnapshot: TimeInterval
    private var lastProgress: TimeInterval
    private var publishedCount = 0

    init(now: TimeInterval) { lastSnapshot = now; lastProgress = now }

    mutating func update(found: Int, now: TimeInterval) -> Update {
        if found - publishedCount >= AskFileIndex.publishEvery || now - lastSnapshot >= 2
            || publishedCount == 0 && now - lastSnapshot >= 0.25 {
            publishedCount = found; lastSnapshot = now; lastProgress = now
            return .snapshot
        }
        if now - lastProgress >= 0.25 { lastProgress = now; return .progress }
        return .none
    }
}
