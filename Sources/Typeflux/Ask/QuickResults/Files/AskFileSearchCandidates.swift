import Foundation

/// A bounded superset selected by character masks, before matching or ranking.
/// Adding query characters can reuse it even when pinyin or fuzzy matching gains
/// new hits. Filters, usage and time are always evaluated again by the scanner.
final class AskFileSearchCandidates: @unchecked Sendable {
    private struct Entry {
        var mask: UInt64
        var includesPaths: Bool
        var recordCount: Int
        var indices: [UInt32]
    }

    private let lock = NSLock()
    private let maximumCandidates: Int
    private let minimumEntries: Int
    private var revision = 0
    private var entry: Entry?

    init(maximumCandidates: Int = 100_000, minimumEntries: Int = AskFileIndexState.chunkSize) {
        self.maximumCandidates = max(0, maximumCandidates)
        self.minimumEntries = max(0, minimumEntries)
    }

    func invalidate(revision: Int) {
        lock.withLock { self.revision = revision; entry = nil }
    }

    func lookup(mask: UInt64, includesPaths: Bool, recordCount: Int, revision: Int) -> [UInt32]? {
        lock.withLock {
            guard self.revision == revision, let entry, entry.recordCount == recordCount,
                  entry.includesPaths == includesPaths, mask & entry.mask == entry.mask else { return nil }
            return entry.indices
        }
    }

    func collector(mask: UInt64, recordCount: Int, chunks: Int) -> Collector? {
        // Broad pools keep the full scan's locality and avoid extra retained memory.
        let capacity = min(maximumCandidates, recordCount / 8)
        guard mask != 0, recordCount >= minimumEntries, capacity > 0 else { return nil }
        return Collector(capacity: capacity, chunks: chunks)
    }

    func store(_ collector: Collector?, mask: UInt64, includesPaths: Bool, recordCount: Int, revision: Int) {
        guard let indices = collector?.indices else { return }
        lock.withLock {
            // A search of an older snapshot must never repopulate an invalidated pool.
            guard self.revision == revision else { return }
            entry = Entry(mask: mask, includesPaths: includesPaths, recordCount: recordCount, indices: indices)
        }
    }

    /// After an overflow, each worker can finish at most one in-flight chunk.
    /// Stored chunks retain their input order so subsequent scans keep locality.
    final class Collector: @unchecked Sendable {
        let capacity: Int
        private let lock = NSLock()
        private var chunks: [[UInt32]]
        private var count = 0
        private var overflow = false

        init(capacity: Int, chunks: Int) {
            self.capacity = capacity
            self.chunks = Array(repeating: [], count: chunks)
        }

        var isCollecting: Bool { lock.withLock { !overflow } }

        func insert(_ indices: [UInt32], chunk: Int, exceeded: Bool) {
            lock.withLock {
                guard !overflow else { return }
                guard !exceeded, count + indices.count <= capacity else {
                    overflow = true
                    chunks.removeAll()
                    return
                }
                count += indices.count
                chunks[chunk] = indices
            }
        }

        var indices: [UInt32]? {
            lock.withLock { overflow ? nil : Array(chunks.joined()) }
        }
    }
}
