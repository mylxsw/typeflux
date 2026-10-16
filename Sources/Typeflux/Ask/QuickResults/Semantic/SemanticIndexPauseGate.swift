import Foundation

/// Pauses background discovery and embedding at directory, file and encoding-batch boundaries.
final class SemanticIndexPauseGate: @unchecked Sendable {
    final class Source: Sendable {
        let lifecycle: AskSearchCancellation
        init(lifecycle: AskSearchCancellation) { self.lifecycle = lifecycle }
    }
    private let lock = NSLock()
    private let standalone = Source(lifecycle: AskSearchCancellation())
    private var source: Source?
    private var paused = false
    private var queries = 0
    private var documents = SemanticFileChangePlan()
    private var documentScan = false
    struct DocumentWork {
        var paths: [String] = []
        var scan = false
        var overflowed = false
    }

    init() { source = standalone }

    /// Binding only replaces queued intents. Actual query occupancy remains until
    /// its original operation ends; a new lifecycle cannot free occupied work.
    func begin(_ source: Source) {
        lock.withLock { self.source = source; documents = .init(); documentScan = false }
    }

    func invalidate() {
        lock.withLock { source = nil; documents = .init(); documentScan = false }
    }

    var isPaused: Bool { lock.withLock { paused || queries > 0 } }
    func beginQuery() { lock.withLock { queries += 1 } }
    func endQuery() { lock.withLock { queries = max(0, queries - 1) } }

    /// A true result requires the owning service to retain a full reconciliation
    /// obligation, including deletions which priority discovery alone cannot prune.
    @discardableResult func enqueueDocuments(_ paths: [String], from source: Source) -> Bool {
        lock.withLock {
            guard self.source === source, !source.lifecycle.isCancelled else { return false }
            for path in paths {
                documents.mergeForHandoff(.init(files: [path]))
                if documents.fullScan { break }
            }
            return documents.fullScan
        }
    }

    func takeDocuments(from source: Source) -> DocumentWork {
        lock.withLock {
            guard self.source === source, !source.lifecycle.isCancelled else { return .init() }
            let work = DocumentWork(paths: documents.files.sorted(), scan: documentScan || documents.fullScan,
                                    overflowed: documents.fullScan)
            documents = .init(); documentScan = false
            return work
        }
    }

    // Standalone/custom indexers keep their original local source. These methods
    // cannot enqueue or drain a service's explicitly bound lifecycle.
    @discardableResult func enqueueDocuments(_ paths: [String]) -> Bool { enqueueDocuments(paths, from: standalone) }
    func takeDocuments() -> DocumentWork { takeDocuments(from: standalone) }
    func enqueueDocumentScan() {
        lock.withLock { if source === standalone { documentScan = true } }
    }
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
}
