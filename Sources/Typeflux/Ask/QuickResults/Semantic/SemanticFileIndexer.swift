import Foundation

enum SemanticMediaFailure: Error { case unavailable(Error) }

enum SemanticFileIndexer {
    struct Summary: Equatable, Sendable {
        var files = 0
        var skipped = 0
        var scanned = 0
        var discovered = 0
        /// The initial workload snapshot; unknown after live events add work during the document phase.
        var total: Int?
        var processed = 0
        var priority: SemanticMediaPriority = .document
        var waitingForIdle = false
        var priorityUpdates = 0
        var diagnostics: SemanticIndexDiagnostics?
    }

    enum Failure: Error { case inference(Error) }

    // Discovery and processing use durable queues; every turn is a bounded extraction/encoding batch.
    // swiftlint:disable:next function_parameter_count
    static func run(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                    encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                    idle: () -> Bool = { true }, paused: () -> Bool = { false },
                    documents: () throws -> SemanticIndexPauseGate.DocumentWork = { .init() },
                    priorityReader: AskFileReading? = nil,
                    cancelled: () -> Bool, progress: (Summary) -> Void,
                    discovered: () throws -> Void = {},
                    current: (String?) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        try maintainSearch(store: store, paused: paused, cancelled: cancelled, summary: summary, progress: progress)
        try discover(scope: scope, store: store, reader: reader, paused: paused,
                     cancelled: cancelled, summary: &summary, progress: progress)
        summary.total = summary.discovered
        progress(summary)
        // Progress can revoke the original scope before its discovery receipt.
        if cancelled() { throw CancellationError() }
        try discovered()
        try waitWhilePaused(paused, cancelled: cancelled)
        // A confirmed walk defines pruning; extraction/encoding failures cannot erase its scope proof.
        // Finish it before consuming another subtree scan, whose discovery snapshot is independent.
        try store.pruneDiscovered(cancelled: cancelled)
        try drainWork(scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                      idle: idle, paused: paused, documents: documents, priorityReader: priorityReader,
                      cancelled: cancelled, summary: &summary, progress: progress, current: current)
        try waitWhilePaused(paused, cancelled: cancelled)
        progress(summary)
        return summary
    }

    // Event replay is idempotent; incomplete paths rotate instead of monopolizing the writer.
    // swiftlint:disable:next function_parameter_count
    static func reconcile(paths: [String], scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                          encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                          idle: () -> Bool = { true }, paused: () -> Bool = { false },
                          documents: () throws -> SemanticIndexPauseGate.DocumentWork = { .init() },
                          priorityReader: AskFileReading? = nil,
                          cancelled: () -> Bool, progress: (Summary) -> Void,
                          directories: [String] = [], prunePending: Bool = false,
                          current: (String?) -> Void = { _ in }) throws -> Summary {
        let entries = Array(Set(paths)).sorted().map { ($0, SemanticMediaPriority.of($0)) }
        if cancelled() { throw CancellationError() }
        _ = try store.discover(entries)
        var summary = Summary()
        try maintainSearch(store: store, paused: paused, cancelled: cancelled, summary: summary, progress: progress)
        for directory in Set(directories).sorted() {
            try waitWhilePaused(paused, cancelled: cancelled)
            try store.beginSubtree(directory)
            try discover(scope: scope, store: store, reader: reader, roots: [directory], paused: paused,
                         cancelled: cancelled, summary: &summary, progress: progress, preparing: false)
            try store.pruneSubtree(directory, cancelled: cancelled)
        }
        summary.total = try store.lock.withLock { try store.count("work_queue") }
        progress(summary)
        try drainWork(scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                      idle: idle, paused: paused, documents: documents, priorityReader: priorityReader,
                      cancelled: cancelled, summary: &summary, progress: progress, current: current)
        if prunePending { try store.pruneDiscovered(cancelled: cancelled) }
        return summary
    }

    // Full discovery and event replay share the same durable round-robin scheduler.
    // swiftlint:disable:next function_parameter_count function_body_length
    private static func drainWork(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                                  encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)?,
                                  idle: () -> Bool, paused: () -> Bool,
                                  documents: () throws -> SemanticIndexPauseGate.DocumentWork,
                                  priorityReader: AskFileReading?, cancelled: () -> Bool,
                                  summary: inout Summary, progress: (Summary) -> Void,
                                  current: (String?) -> Void) throws {
        // Prefer bounded document bursts at each segment boundary. A continuing document stream
        // must not indefinitely postpone every image, audio or video checkpoint.
        while true {
            summary.priority = .document
            progress(summary)
            try drainDocuments(scope: scope, store: store, reader: reader, encoder: encoder,
                               paused: paused, documents: documents, cancelled: cancelled,
                               updates: false, summary: &summary, progress: progress, current: current)
            encoder.release()
            if SemanticWorkBudget.current?.enabled == true, try store.nextWork(.document) != nil {
                // Priority updates are tracked separately, so the initial fixed denominator no
                // longer describes interleaved work accurately.
                summary.total = nil
            }
            var advanced = false
            for priority in [SemanticMediaPriority.image, .audio, .video] {
                summary.priority = priority
                guard let path = try store.nextWork(priority) else { continue }
                advanced = true
                progress(summary)
                try waitWhilePaused(paused, cancelled: cancelled)
                current(path)
                defer { current(nil) }
                let started = ProcessInfo.processInfo.systemUptime
                let result: SemanticFileStore.JobState
                do {
                    result = try process(path, scope: scope, store: store, reader: reader, encoder: encoder,
                                         media: media, cancelled: cancelled, checkpoint: { try waitWhilePaused(
                                             paused,
                                             cancelled: cancelled
                                         ) },
                                         waitForIdle: {
                                             try waitForMedia(
                                                 scope: scope,
                                                 store: store,
                                                 reader: priorityReader ?? reader,
                                                 encoder: encoder,
                                                 idle: idle,
                                                 paused: paused,
                                                 documents: documents,
                                                 cancelled: cancelled,
                                                 summary: &summary,
                                                 progress: progress,
                                                 current: current
                                             )
                                             current(path)
                                         })
                } catch {
                    store.recordInterruptedWork(path, elapsed: ProcessInfo.processInfo.systemUptime - started)
                    throw error
                }
                try store.completeWork(path, more: result == .partial,
                                       elapsed: ProcessInfo.processInfo.systemUptime - started)
                if result != .partial {
                    if result == .done {
                        summary.files += 1
                    } else {
                        summary.skipped += 1
                    }
                    summary.processed += 1
                }
                progress(summary)
            }
            if !advanced, try store.nextWork(.document) == nil {
                break
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func process(_ path: String, scope: AskFileScope, store: SemanticFileStore,
                        reader: AskFileReading, encoder: SemanticEmbedding,
                        media: (any SemanticMediaEmbedding)?,
                        cancelled: () -> Bool, checkpoint: () throws -> Void,
                        waitForIdle: () throws -> Void) throws -> SemanticFileStore.JobState {
        while true {
            do {
                return try autoreleasepool {
                    try index(path, scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                              cancelled: cancelled, checkpoint: checkpoint, waitForIdle: waitForIdle)
                }
            } catch is SemanticWorkBudget.Interrupted {
                encoder.release(); media?.release()
                try store.setStage(.waiting)
                try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
                continue
            } catch {
                if cancelled() {
                    throw CancellationError()
                }
                if error is SemanticFileStore.Failure {
                    throw error
                }
                if case let Failure.inference(cause) = error {
                    try store.failJob(path, reason: "encoding-failed"); throw cause
                }
                if error is SemanticMediaFailure {
                    try store.failJob(path, reason: "media-encoding-failed"); throw error
                }
                try store.failJob(path, reason: error is AskFileReadError ? "reader-failed" : "extraction-failed")
                return .skipped
            }
        }
    }

    static func waitWhilePaused(_ paused: () -> Bool, cancelled: () -> Bool) throws {
        try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
        while paused() {
            if cancelled() {
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if cancelled() {
            throw CancellationError()
        }
    }

    private static func maintainSearch(store: SemanticFileStore, paused: () -> Bool, cancelled: () -> Bool,
                                       summary: Summary, progress: (Summary) -> Void) throws {
        while true {
            try waitWhilePaused(paused, cancelled: cancelled)
            guard try store.maintainSearchBatch(cancelled: cancelled) else { return }
            try store.setStage(.migration)
            progress(summary)
        }
    }
}
