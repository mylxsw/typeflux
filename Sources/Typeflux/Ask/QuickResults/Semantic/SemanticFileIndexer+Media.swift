import Foundation

extension SemanticFileIndexer {
    // Each file's staged vectors remain invisible until extraction and metadata checks finish.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func indexMedia(_ path: String, metadata: AskFileReadResponse, scope: AskFileScope,
                           store: SemanticFileStore, reader: AskFileReading, media: any SemanticMediaEmbedding,
                           cancelled: () -> Bool, waitForIdle: () throws -> Void) throws -> Bool {
        try waitForIdle()
        let generation = try store.beginMediaJob(path: path, metadata: metadata)
        try store.removeOrphanMediaCache(cancelled: cancelled)
        let resume = try store.mediaCursor(path: path, generation: generation)
        let scratch = store.url.deletingLastPathComponent().appendingPathComponent(
            ".typeflux-media-cache",
            isDirectory: true
        )
        .appendingPathComponent(generation)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Preserve the verified snapshot on pause/cancellation. A successful publication removes it.
        let initialInterruptions = SemanticWorkBudget.current?.statistics.interruptions ?? 0
        var committedScratch = false
        defer {
            let interrupted = (SemanticWorkBudget.current?.statistics.interruptions ?? 0) > initialInterruptions
            if committedScratch || (!cancelled() && !interrupted) {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        try store.record(.vectorReusedSegments, count: resume.nextOrdinal)
        var ordinal = 0
        var failure: Error?, final: AskFileReadResponse?
        try store.setStage(.extracting)
        try store.record(.extractionBatches)
        try reader.stream(
            .init(operation: .media, path: path, scope: scope, scratch: scratch.path, paced: true, mediaCursor: resume),
            isCancelled: cancelled
        ) { response in
            if let input = response.media {
                if let supplied = response.mediaOrdinal {
                    ordinal = supplied
                }
                do {
                    guard (input.path as NSString).deletingLastPathComponent == scratch.path else {
                        throw AskFileReadError.protocolError
                    }
                    try waitForIdle()
                    defer { ordinal += 1 }
                    if try store.hasMediaSegment(path: path, generation: generation, ordinal: ordinal) {
                        try store.record(.vectorReusedSegments)
                        try? FileManager.default.removeItem(atPath: input.path)
                        return !cancelled()
                    }
                    let vector: [Float]
                    try store.setStage(.encoding)
                    try store.record(.encodingRequests)
                    do {
                        vector = try media.embed(input, cancelled: cancelled)
                    } catch is SemanticWorkBudget.Interrupted {
                        throw SemanticWorkBudget.Interrupted()
                    } catch let error as SemanticMediaInputError {
                        throw error
                    } catch { throw SemanticMediaFailure.unavailable(error) }
                    try store.record(.vectorsInferred)
                    try store.saveMediaSegment(
                        path: path,
                        generation: generation,
                        ordinal: ordinal,
                        input: input,
                        vector: vector
                    )
                    try? FileManager.default.removeItem(atPath: input.path)
                } catch { failure = error; return false }
            }
            if response.more != true {
                final = response
                ordinal = response.mediaSegments ?? ordinal
            }
            return !cancelled()
        }
        if cancelled() {
            throw CancellationError()
        }
        if let failure {
            throw failure
        }
        let after = try reader.read(.init(operation: .content, path: path, scope: scope, readText: false),
                                    isCancelled: cancelled)
        guard after.error == nil, SemanticFileStore.version(after) == SemanticFileStore.version(metadata) else {
            try store.skipUnavailable(path, reason: "media-missing-or-changed")
            return false
        }
        guard final?.error == nil, final?.modified == metadata.modified, final?.fileSize == metadata.fileSize else {
            // Keep completed private vectors for the same verified file version when its decoder fails.
            try store.failJob(path, reason: "media-extraction-failed")
            return false
        }
        if ordinal == 0 {
            try store.skipUnavailable(path, reason: "empty-or-no-media")
            return false
        }
        let committed = try store.commitMediaJob(
            path: path,
            generation: generation,
            metadata: metadata,
            segments: ordinal
        )
        if !committed {
            try store.failJob(path, reason: "inconsistent-media-segments")
        }
        committedScratch = committed
        return committed
    }
}
