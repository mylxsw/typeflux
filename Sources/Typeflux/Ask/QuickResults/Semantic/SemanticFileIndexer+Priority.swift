import Foundation

extension SemanticFileIndexer {
    // A separate reader allows document work while the media reader is suspended inside a stream callback.
    // swiftlint:disable:next function_parameter_count
    static func waitForMedia(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                             encoder: SemanticEmbedding, idle: () -> Bool, paused: () -> Bool,
                             documents: () -> SemanticIndexPauseGate.DocumentWork, cancelled: () -> Bool,
                             summary: inout Summary, progress: (Summary) -> Void) throws {
        repeat {
            try waitWhilePaused(paused, cancelled: cancelled)
            let work = documents()
            func update(_ paths: [String]) throws {
                guard !paths.isEmpty else { return }
                _ = try store.discover(paths.map { ($0, .document) })
                let updates = try reconcile(paths: paths, scope: scope, store: store, reader: reader, encoder: encoder,
                                            paused: paused, cancelled: cancelled, progress: { _ in })
                summary.priorityUpdates += updates.processed
                encoder.release()
                progress(summary)
            }
            try update(work.paths)
            if work.scan {
                try discoverPriorityDocuments(scope: scope, store: store, reader: reader, paused: paused,
                                              cancelled: cancelled, skipped: { summary.skipped += 1 })
                var after = ""
                while true {
                    let paths = try store.candidates(.document, after: after)
                    guard !paths.isEmpty else { break }
                    try update(paths)
                    after = paths.last!
                }
            }
            if idle() {
                if summary.waitingForIdle {
                    summary.waitingForIdle = false; progress(summary)
                }
                return
            }
            if !summary.waitingForIdle {
                summary.waitingForIdle = true; progress(summary)
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while !cancelled()
        throw CancellationError()
    }

    // Disk-backed discovery finishes its stream before any document reads begin.
    // swiftlint:disable:next function_parameter_count
    private static func discoverPriorityDocuments(scope: AskFileScope, store: SemanticFileStore,
                                                  reader: AskFileReading, paused: () -> Bool,
                                                  cancelled: () -> Bool, skipped: () -> Void) throws {
        var batch: [(String, SemanticMediaPriority)] = [], failure: Error?
        func flushDiscovery() throws {
            _ = try store.discover(batch)
            batch.removeAll(keepingCapacity: true)
        }
        for root in scope.roots {
            AskFileCrawler.crawl(root, scope: scope, limit: nil, reader: reader, isCancelled: cancelled,
                                 isPaused: paused, skipped: { _, _ in skipped() }, visit: { entry in
                                     if entry.kind == .file, SemanticFilePolicy.allows(entry.path),
                                        SemanticMediaPriority.of(entry.path) == .document {
                                         batch.append((entry.path, .document))
                                     }
                                     do {
                                         if batch.count >= 128 {
                                             try flushDiscovery()
                                         }
                                     } catch {
                                         failure = error; return false
                                     }
                                     return !cancelled()
                                 })
            if let failure {
                throw failure
            }
            if cancelled() {
                throw CancellationError()
            }
        }
        try flushDiscovery()
    }
}
