import Foundation

extension SemanticFileIndexer {
    // Each file's staged vectors remain invisible until extraction and metadata checks finish.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func indexMedia(_ path: String, metadata: AskFileReadResponse, scope: AskFileScope,
                           store: SemanticFileStore, reader: AskFileReading, encoder: SemanticEmbedding,
                           media: any SemanticMediaEmbedding,
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
        do {
            try reader.stream(
                .init(
                    operation: .media,
                    path: path,
                    scope: scope,
                    scratch: scratch.path,
                    paced: true,
                    mediaCursor: resume
                ),
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
                        if cancelled() {
                            throw CancellationError()
                        }
                        try store.saveMediaSegment(
                            path: path,
                            generation: generation,
                            ordinal: ordinal,
                            input: input,
                            vector: vector,
                            audioProgress: response.audioProgress,
                            videoProgress: response.videoProgress
                        )
                        try? FileManager.default.removeItem(atPath: input.path)
                    } catch { failure = error; return false }
                }
                if response.media == nil, let progress = response.videoProgress {
                    do {
                        try waitForIdle()
                        if cancelled() { throw CancellationError() }
                        try store.saveVideoProgress(path: path, generation: generation, progress: progress)
                    } catch { failure = error; return false }
                }
                if response.media == nil, let progress = response.audioProgress {
                    do {
                        try waitForIdle()
                        if cancelled() { throw CancellationError() }
                        try store.saveAudioProgress(path: path, generation: generation, progress: progress)
                    } catch { failure = error; return false }
                }
                if let pages = response.pages {
                    do {
                        try waitForIdle()
                        let chunks = SemanticChunk.make(pages)
                        let title = String(path.split(separator: "/").last ?? "").prefix(80)
                        for start in stride(from: 0, to: chunks.count, by: 8) {
                            let batch = Array(chunks[start ..< min(start + 8, chunks.count)])
                            if try store.hasMediaText(path: path, generation: generation, chunks: batch) {
                                continue
                            }
                            try waitForIdle()
                            try store.setStage(.encoding)
                            try store.record(.encodingRequests)
                            let vectors = try encoder.embed(batch.map { "title: \(title) | text: " + $0.text },
                                                            cancelled: cancelled)
                            if cancelled() {
                                throw CancellationError()
                            }
                            try store.saveMediaText(path: path, generation: generation, chunks: batch, vectors: vectors)
                        }
                    } catch { failure = error; return false }
                }
                if response.more != true {
                    final = response
                    ordinal = response.mediaSegments ?? ordinal
                }
                return !cancelled()
            }
        } catch {
            if cancelled() {
                throw CancellationError()
            }
            throw error
        }
        if cancelled() {
            throw CancellationError()
        }
        if let failure {
            throw failure
        }
        let after = try reader.read(.init(operation: .content, path: path, scope: scope, readText: false),
                                    isCancelled: cancelled)
        if cancelled() {
            throw CancellationError()
        }
        guard after.error == nil, SemanticFileStore.version(after) == SemanticFileStore.version(metadata) else {
            try store.skipUnavailable(
                path,
                reason: after.error == EACCES ? "permission-denied" : "media-missing-or-changed"
            )
            return false
        }
        let ocrFailed = final?.error == EIO && SemanticMediaPriority.of(path) == .image
        guard final?.error == nil || ocrFailed, final?.modified == metadata.modified,
              final?.fileSize == metadata.fileSize else {
            // Keep completed private vectors for the same verified file version when its decoder fails.
            try store.failJob(path, reason: "media-extraction-failed")
            return false
        }
        let saved = try store.mediaCursor(path: path, generation: generation)
        let completedAudio = SemanticMediaPriority.of(path) == .audio && saved.audioCoveredUntil > 0
        if ordinal == 0 && !completedAudio {
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
        if committed, ocrFailed {
            try store.failJob(path, reason: "image-ocr-failed")
        }
        committedScratch = committed
        return committed && !ocrFailed
    }
}
