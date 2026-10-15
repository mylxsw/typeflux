import Foundation

/// Pauses background discovery and embedding at directory, file and encoding-batch boundaries.
final class SemanticIndexPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var queries = 0
    private var documents = Set<String>()
    private var documentScan = false
    struct DocumentWork {
        var paths: [String] = []
        var scan = false
    }

    var isPaused: Bool {
        lock.withLock { paused || queries > 0 }
    }

    func beginQuery() {
        lock.withLock { queries += 1 }
    }

    func endQuery() {
        lock.withLock { queries = max(0, queries - 1) }
    }

    func enqueueDocuments(_ paths: [String]) {
        lock.withLock { documents.formUnion(paths) }
    }

    func enqueueDocumentScan() { lock.withLock { documentScan = true } }

    func takeDocuments() -> DocumentWork {
        lock.withLock {
            let work = DocumentWork(paths: documents.sorted(), scan: documentScan)
            documents.removeAll(); documentScan = false
            return work
        }
    }

    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
}
