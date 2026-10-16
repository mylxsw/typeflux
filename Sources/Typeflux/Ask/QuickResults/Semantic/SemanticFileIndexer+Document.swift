import Foundation

extension SemanticFileIndexer {
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func index(_ path: String, scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                      encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)?, cancelled: () -> Bool,
                      checkpoint: () throws -> Void, waitForIdle: () throws -> Void) throws -> SemanticFileStore
        .JobState {
        guard scope.includes(path, isDirectory: false), SemanticFilePolicy.allows(path) else {
            try store.remove(path); return .skipped
        }
        try store.setStage(.checking)
        let metadata = try reader.read(.init(operation: .content, path: path, scope: scope, readText: false),
                                       isCancelled: cancelled)
        guard metadata.error == nil, metadata.modified != nil, metadata.fileSize != nil else {
            try store.skipUnavailable(
                path,
                reason: metadata.error == EACCES ? "permission-denied" : "missing-or-unavailable"
            )
            return .skipped
        }
        if SemanticMediaPriority.of(path) != .document {
            if try store.mediaUnchanged(path: path, metadata: metadata) {
                try store.record(.metadataReused)
                try store.record(.vectorReusedFiles)
                return .done
            }
            guard let media else { return .skipped }
            return try indexMedia(path, metadata: metadata, scope: scope, store: store, reader: reader,
                                  media: media, cancelled: cancelled, waitForIdle: waitForIdle) ? .done : .skipped
        }
        let job = try store.prepareDocument(path: path, metadata: metadata)
        if job.state == .done || job.state == .skipped {
            try store.record(.metadataReused)
            if job.state == .done {
                try store.record(.vectorReusedFiles)
            }
            return job.state
        }
        func verify() throws -> Bool {
            if cancelled() {
                throw CancellationError()
            }
            let after: AskFileReadResponse
            do {
                after = try reader.read(.init(operation: .content, path: path, scope: scope, readText: false),
                                        isCancelled: cancelled)
            } catch {
                if cancelled() {
                    throw CancellationError()
                }
                try store.skipUnavailable(path, reason: "metadata-unavailable")
                throw error
            }
            guard after.error == nil, SemanticFileStore.version(after) == job.version else {
                let reason = after.error == EACCES ? "permission-denied" : "file-missing-or-changed"
                try store.skipUnavailable(path, reason: reason)
                return false
            }
            return true
        }
        var work = try store.vectorWork(job)
        if work.isEmpty, !job.extracted {
            let tail = job.cursor.offset > 0 || job.cursor.page > 0
            try store.setStage(tail ? .tail : .extracting)
            if tail {
                try store.record(.tailBatches)
            }
            try store.record(.extractionBatches)
            let contents = try reader.read(.init(operation: .content, path: path, scope: scope, cursor: job.cursor),
                                           isCancelled: cancelled)
            guard contents.error == nil, SemanticFileStore.version(contents) == job.version,
                  let pages = contents.pages else {
                if contents.error == EACCES || contents.error == ENOENT || contents.error == EAGAIN {
                    let reason = contents.error == EACCES ? "permission-denied" : "file-missing-or-changed"
                    try store.skipUnavailable(path, reason: reason)
                } else {
                    let reason = contents.error == EAUTH ? "password-required"
                        : contents.error == EIO && (path as NSString).pathExtension.lowercased() == "pdf"
                        ? "pdf-ocr-failed" : "unreadable-content"
                    try store.failJob(path, reason: reason)
                }
                return .skipped
            }
            if let next = contents.nextCursor {
                let advances = next.page > job.cursor.page
                    || (next.page == job.cursor.page && next.offset > job.cursor.offset)
                guard advances else {
                    throw AskFileReadError.protocolError
                }
            }
            guard try verify() else { return .skipped }
            guard try store.publish(SemanticChunk.make(pages), next: contents.nextCursor, job: job)
            else { return .skipped }
            work = try store.vectorWork(job)
        }
        if SemanticWorkBudget.current?.enabled == true {
            work = Array(work.prefix(1))
        }
        if !work.isEmpty {
            try checkpoint()
            try store.setStage(.encoding)
            try store.record(.encodingRequests)
            let title = String(path.split(separator: "/").last ?? "").prefix(80)
            let texts = work.map { "title: \(title) | text: " + $0.text }
            let vectors: [[Float]]
            do {
                vectors = try encoder.embed(texts, cancelled: cancelled)
            } catch is SemanticWorkBudget.Interrupted {
                throw SemanticWorkBudget.Interrupted()
            } catch { throw Failure.inference(error) }
            try store.record(.vectorsInferred, count: vectors.count)
            guard try verify() else { return .skipped }
            guard try store.publishVectors(vectors, work: work, job: job) else { return .skipped }
        }
        return try store.finishDocument(job)
    }
}
