import Foundation

extension SemanticFileIndexer {
    // Each file's staged vectors remain invisible until extraction and metadata checks finish.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func indexMedia(_ path: String, metadata: AskFileReadResponse, scope: AskFileScope,
                           store: SemanticFileStore, reader: AskFileReading, media: any SemanticMediaEmbedding,
                           cancelled: () -> Bool, waitForIdle: () throws -> Void) throws -> Bool {
        try waitForIdle()
        let scratch = URL(fileURLWithPath: AskFileScope.canonical(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("typeflux-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let generation = try store.beginMediaJob(path: path, metadata: metadata)
        var ordinal = 0
        var failure: Error?, final: AskFileReadResponse?
        try reader.stream(.init(operation: .media, path: path, scope: scope, scratch: scratch.path),
                          isCancelled: cancelled) { response in
            if let input = response.media {
                do {
                    guard (input.path as NSString).deletingLastPathComponent == scratch.path else {
                        throw AskFileReadError.protocolError
                    }
                    try waitForIdle()
                    defer { ordinal += 1 }
                    if try store.hasMediaSegment(path: path, generation: generation, ordinal: ordinal) {
                        try? FileManager.default.removeItem(atPath: input.path)
                        return !cancelled()
                    }
                    let vector: [Float]
                    do {
                        vector = try media.embed(input, cancelled: cancelled)
                    } catch let error as SemanticMediaInputError {
                        throw error
                    } catch { throw SemanticMediaFailure.unavailable(error) }
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
        return committed
    }
}
