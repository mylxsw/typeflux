import Foundation

enum SemanticMediaFailure: Error { case unavailable(Error) }

enum SemanticFileIndexer {
    struct Summary: Equatable, Sendable {
        var files = 0
        var skipped = 0
        var scanned = 0
        var discovered = 0
        /// The initial discovery snapshot; later document refreshes are counted separately.
        var total: Int?
        var processed = 0
        var priority: SemanticMediaPriority = .document
        var waitingForIdle = false
        var priorityUpdates = 0
    }

    enum Failure: Error { case inference(Error) }

    // Discovery and processing use durable queues; every turn is a bounded extraction/encoding batch.
    // swiftlint:disable:next function_parameter_count function_body_length
    static func run(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                    encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                    idle: () -> Bool = { true }, paused: () -> Bool = { false },
                    documents: () -> SemanticIndexPauseGate.DocumentWork = { .init() },
                    priorityReader: AskFileReading? = nil,
                    cancelled: () -> Bool, progress: (Summary) -> Void) throws -> Summary {
        var summary = Summary()
        try discover(scope: scope, store: store, reader: reader, paused: paused,
                     cancelled: cancelled, summary: &summary, progress: progress)
        summary.total = summary.discovered
        progress(summary)
        for priority in SemanticMediaPriority.allCases {
            summary.priority = priority
            if priority == .image {
                encoder.release()
            }
            progress(summary)
            while let path = try store.nextWork(priority) {
                try waitWhilePaused(paused, cancelled: cancelled)
                let result = try process(path, scope: scope, store: store, reader: reader, encoder: encoder,
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
                                                 progress: progress
                                             )
                                         })
                try store.completeWork(path, more: result == .partial)
                if result != .partial {
                    if result == .done {
                        summary.files += 1
                    } else {
                        summary.skipped += 1
                    }
                    summary.processed += 1
                }
                progress(summary)
                if priority == .document {
                    // New small documents can preempt between batches of a large document too.
                    try waitForMedia(scope: scope, store: store, reader: priorityReader ?? reader,
                                     encoder: encoder, idle: { true }, paused: paused, documents: documents,
                                     cancelled: cancelled, summary: &summary, progress: progress)
                }
            }
        }
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
                          cancelled: () -> Bool, progress: (Summary) -> Void) throws -> Summary {
        let paths = Array(Set(paths)).sorted()
        try store.enqueue(paths.map { ($0, SemanticMediaPriority.of($0)) })
        var summary = Summary()
        summary.total = paths.count
        progress(summary)
        for priority in SemanticMediaPriority.allCases {
            summary.priority = priority
            if priority == .image {
                encoder.release()
            }
            var remaining = paths.filter { SemanticMediaPriority.of($0) == priority }
            while !remaining.isEmpty {
                var partial: [String] = []
                for path in remaining {
                    try waitWhilePaused(paused, cancelled: cancelled)
                    let result = try process(path, scope: scope, store: store, reader: reader, encoder: encoder,
                                             media: media, cancelled: cancelled,
                                             checkpoint: { try waitWhilePaused(paused, cancelled: cancelled) },
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
                                                     progress: progress
                                                 )
                                             })
                    try store.completeWork(path, more: result == .partial)
                    if result == .partial {
                        partial.append(path)
                    } else {
                        if result == .done {
                            summary.files += 1
                        } else {
                            summary.skipped += 1
                        }
                        summary.processed += 1
                    }
                    progress(summary)
                }
                remaining = partial
            }
        }
        return summary
    }

    // swiftlint:disable:next function_parameter_count
    private static func process(_ path: String, scope: AskFileScope, store: SemanticFileStore,
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
