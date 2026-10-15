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
            try drainDocuments(scope: scope, store: store, reader: reader, encoder: encoder,
                               paused: paused, documents: documents, cancelled: cancelled,
                               updates: true, summary: &summary, progress: progress)
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

    // Consume events at every document batch boundary. Partial files rotate in the durable queue;
    // never recursively reconcile a live event's whole file before checking the next event.
    // swiftlint:disable:next function_parameter_count
    static func drainDocuments(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                               encoder: SemanticEmbedding, paused: () -> Bool,
                               documents: () -> SemanticIndexPauseGate.DocumentWork, cancelled: () -> Bool,
                               updates: Bool, summary: inout Summary, progress: (Summary) -> Void) throws {
        var processedWork = false
        defer {
            if updates, processedWork {
                encoder.release()
            }
        }
        while true {
            try waitWhilePaused(paused, cancelled: cancelled)
            let work = documents()
            if !updates, work.scan || !work.paths.isEmpty {
                // A live event invalidates the initial workload snapshot.
                summary.total = nil
            }
            if !work.paths.isEmpty {
                _ = try store.discover(work.paths.map { ($0, .document) })
            }
            if work.scan {
                try discoverPriorityDocuments(scope: scope, store: store, reader: reader, paused: paused,
                                              cancelled: cancelled, skipped: { summary.skipped += 1 })
            }
            guard let path = try store.nextWork(.document) else { return }
            processedWork = true
            let result = try process(path, scope: scope, store: store, reader: reader, encoder: encoder,
                                     media: nil, cancelled: cancelled,
                                     checkpoint: { try waitWhilePaused(paused, cancelled: cancelled) },
                                     waitForIdle: {})
            try store.completeWork(path, more: result == .partial)
            if result != .partial {
                if updates {
                    summary.priorityUpdates += 1
                } else {
                    if result == .done {
                        summary.files += 1
                    } else {
                        summary.skipped += 1
                    }
                    summary.processed += 1
                }
            }
            progress(summary)
        }
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
