import Foundation

extension SemanticFileIndexer {
    // A separate reader allows document work while the media reader is suspended inside a stream callback.
    // swiftlint:disable:next function_parameter_count
    static func waitForMedia(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                             encoder: SemanticEmbedding, idle: () -> Bool, paused: () -> Bool,
                             documents: () throws -> SemanticIndexPauseGate.DocumentWork, cancelled: () -> Bool,
                             summary: inout Summary, progress: (Summary) -> Void,
                             current: (String?) -> Void) throws {
        repeat {
            try waitWhilePaused(paused, cancelled: cancelled)
            try drainDocuments(scope: scope, store: store, reader: reader, encoder: encoder,
                               paused: paused, documents: documents, cancelled: cancelled,
                               updates: true, summary: &summary, progress: progress, current: current)
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
                               documents: () throws -> SemanticIndexPauseGate.DocumentWork, cancelled: () -> Bool,
                               updates: Bool, summary: inout Summary, progress: (Summary) -> Void,
                               current: (String?) -> Void) throws {
        var processedWork = false
        var batches = 0
        let limit = SemanticWorkBudget.current?.documentBatchLimit
        defer {
            if updates, processedWork {
                encoder.release()
            }
        }
        while true {
            if let limit, batches >= limit {
                return
            }
            try waitWhilePaused(paused, cancelled: cancelled)
            let work = try documents()
            if !updates, work.scan || !work.paths.isEmpty {
                // A live event invalidates the initial workload snapshot.
                summary.total = nil
            }
            if !work.paths.isEmpty {
                _ = try store.discover(work.paths.map { ($0, .document) })
            }
            if work.scan {
                // Compatibility callers request a document-only scan. Real filesystem subtrees
                // use the durable scan-request queue below and confirm all supported modalities.
                try discover(scope: scope, store: store, reader: reader, roots: scope.roots, paused: paused,
                             cancelled: cancelled, summary: &summary, progress: progress)
                try store.pruneDiscovered(cancelled: cancelled, documentsOnly: true)
            }
            while let request = try store.nextScanRequest() {
                summary.total = nil
                try discover(scope: scope, store: store, reader: reader, roots: [request.path], paused: paused,
                             cancelled: cancelled, summary: &summary, progress: progress)
                try waitWhilePaused(paused, cancelled: cancelled)
                try store.pruneDiscovered(cancelled: cancelled)
                try store.finishScanRequest(request)
            }
            guard let path = try store.nextWork(.document) else { return }
            processedWork = true
            current(path)
            defer { current(nil) }
            let started = ProcessInfo.processInfo.systemUptime
            let result: SemanticFileStore.JobState
            do {
                result = try process(path, scope: scope, store: store, reader: reader, encoder: encoder,
                                     media: nil, cancelled: cancelled,
                                     checkpoint: { try waitWhilePaused(paused, cancelled: cancelled) },
                                     waitForIdle: {})
            } catch {
                store.recordInterruptedWork(path, elapsed: ProcessInfo.processInfo.systemUptime - started)
                throw error
            }
            try store.completeWork(path, more: result == .partial,
                                   elapsed: ProcessInfo.processInfo.systemUptime - started)
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
            batches += 1
        }
    }
}
