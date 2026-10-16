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
    }

    enum Failure: Error { case inference(Error) }

    // Discovery and processing use durable queues; every turn is a bounded extraction/encoding batch.
    // swiftlint:disable:next function_parameter_count
    static func run(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                    encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                    idle: () -> Bool = { true }, paused: () -> Bool = { false },
                    documents: () -> SemanticIndexPauseGate.DocumentWork = { .init() },
                    priorityReader: AskFileReading? = nil,
                    cancelled: () -> Bool, progress: (Summary) -> Void,
                    current: (String?) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        try discover(scope: scope, store: store, reader: reader, paused: paused,
                     cancelled: cancelled, summary: &summary, progress: progress)
        summary.total = summary.discovered
        progress(summary)
        try drainWork(scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                      idle: idle, paused: paused, documents: documents, priorityReader: priorityReader,
                      cancelled: cancelled, summary: &summary, progress: progress, current: current)
        try waitWhilePaused(paused, cancelled: cancelled)
        try store.pruneDiscovered(cancelled: cancelled)
        progress(summary)
        return summary
    }

    // Event replay is idempotent; incomplete paths rotate instead of monopolizing the writer.
    // swiftlint:disable:next function_parameter_count
    static func reconcile(paths: [String], scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                          encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                          idle: () -> Bool = { true }, paused: () -> Bool = { false },
                          documents: () -> SemanticIndexPauseGate.DocumentWork = { .init() },
                          priorityReader: AskFileReading? = nil,
                          cancelled: () -> Bool, progress: (Summary) -> Void,
                          current: (String?) -> Void = { _ in }) throws -> Summary {
        let paths = Array(Set(paths)).sorted()
        _ = try store.discover(paths.map { ($0, SemanticMediaPriority.of($0)) })
        var summary = Summary()
        summary.total = try store.lock.withLock { try store.count("work_queue") }
        progress(summary)
        try drainWork(scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                      idle: idle, paused: paused, documents: documents, priorityReader: priorityReader,
                      cancelled: cancelled, summary: &summary, progress: progress, current: current)
        return summary
    }

    // Full discovery and event replay share the same durable round-robin scheduler.
    // swiftlint:disable:next function_parameter_count
    private static func drainWork(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                                  encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)?,
                                  idle: () -> Bool, paused: () -> Bool,
                                  documents: () -> SemanticIndexPauseGate.DocumentWork,
                                  priorityReader: AskFileReading?, cancelled: () -> Bool,
                                  summary: inout Summary, progress: (Summary) -> Void,
                                  current: (String?) -> Void) throws {
        for priority in SemanticMediaPriority.allCases {
            summary.priority = priority
            if priority == .image {
                encoder.release()
            }
            progress(summary)
            if priority == .document {
                try drainDocuments(scope: scope, store: store, reader: reader, encoder: encoder,
                                   paused: paused, documents: documents, cancelled: cancelled,
                                   updates: false, summary: &summary, progress: progress, current: current)
                continue
            }
            while let path = try store.nextWork(priority) {
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
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func process(_ path: String, scope: AskFileScope, store: SemanticFileStore,
                        reader: AskFileReading, encoder: SemanticEmbedding,
                        media: (any SemanticMediaEmbedding)?,
                        cancelled: () -> Bool, checkpoint: () throws -> Void,
                        waitForIdle: () throws -> Void) throws -> SemanticFileStore.JobState {
        do {
            return try index(path, scope: scope, store: store, reader: reader, encoder: encoder, media: media,
                             cancelled: cancelled, checkpoint: checkpoint, waitForIdle: waitForIdle)
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

    static func waitWhilePaused(_ paused: () -> Bool, cancelled: () -> Bool) throws {
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
}
