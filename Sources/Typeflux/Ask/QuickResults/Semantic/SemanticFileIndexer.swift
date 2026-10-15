import Foundation

enum SemanticMediaFailure: Error { case unavailable(Error) }

enum SemanticFileIndexer {
    struct Summary: Equatable, Sendable {
        var files = 0
        var skipped = 0
        var scanned = 0
        var discovered = 0
        var total: Int?
        var processed = 0
        var priority: SemanticMediaPriority = .document
        var waitingForIdle = false
    }
    private enum Failure: Error { case inference(Error) }

    // Each file's staged vectors remain invisible until extraction and metadata checks finish.
    // swiftlint:disable:next function_parameter_count
    private static func indexMedia(_ path: String, metadata: AskFileReadResponse, scope: AskFileScope,
                                   store: SemanticFileStore, reader: AskFileReading, media: any SemanticMediaEmbedding,
                                   cancelled: () -> Bool, waitForIdle: () throws -> Void) throws -> Bool {
        try waitForIdle()
        let scratch = URL(fileURLWithPath: AskFileScope.canonical(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("typeflux-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        try store.beginMedia()
        defer { try? store.beginMedia() }
        var failure: Error?, final: AskFileReadResponse?
        try reader.stream(.init(operation: .media, path: path, scope: scope, scratch: scratch.path),
                          isCancelled: cancelled) { response in
            if let input = response.media {
                do {
                    guard (input.path as NSString).deletingLastPathComponent == scratch.path else {
                        throw AskFileReadError.protocolError
                    }
                    try waitForIdle()
                    let vector: [Float]
                    do {
                        vector = try media.embed(input, cancelled: cancelled)
                    } catch let error as SemanticMediaInputError {
                        throw error
                    } catch { throw SemanticMediaFailure.unavailable(error) }
                    try store.stageMedia(vector, time: input.time)
                    try? FileManager.default.removeItem(atPath: input.path)
                } catch { failure = error; return false }
            }
            if response.more != true { final = response }
            return !cancelled()
        }
        if cancelled() { throw CancellationError() }
        if let failure { throw failure }
        let after = try reader.read(.init(operation: .content, path: path, scope: scope, readText: false),
                                    isCancelled: cancelled)
        guard final?.error == nil, final?.modified == metadata.modified, final?.fileSize == metadata.fileSize,
              after.error == nil, after.modified == metadata.modified, after.fileSize == metadata.fileSize,
              let modified = metadata.modified, let bytes = metadata.fileSize else {
            try store.remove(path); return false
        }
        return try store.commitMedia(path: path, modified: modified, bytes: bytes)
    }
    // Discover once into a disk-backed queue, then process documents before idle-only media.
    // No directory-entry or total-chunk quota can truncate the selected scope.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func run(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                    encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                    idle: () -> Bool = { true }, paused: () -> Bool = { false }, cancelled: () -> Bool,
                    progress: (Summary) -> Void) throws -> Summary {
        var summary = Summary(), failure: Error?
        try store.beginDiscovery()
        var batch: [(String, SemanticMediaPriority)] = []
        func flush() throws {
            summary.discovered += try store.discover(batch); batch.removeAll(keepingCapacity: true)
        }
        for root in scope.roots {
            AskFileCrawler.crawl(root, scope: scope, limit: nil, reader: reader, isCancelled: cancelled,
                isPaused: paused,
                skipped: { _, _ in summary.skipped += 1 }, visit: { entry in
                    summary.scanned += 1
                    if entry.kind == .file, SemanticFilePolicy.allows(entry.path) {
                        batch.append((entry.path, SemanticMediaPriority.of(entry.path)))
                    }
                    do { if batch.count >= 128 { try flush() } } catch { failure = error; return false }
                    if summary.scanned.isMultiple(of: 1_000) { progress(summary) }
                    return !cancelled()
                })
            if cancelled() { throw CancellationError() }
            if let failure { throw failure }
        }
        try flush()
        summary.total = summary.discovered
        progress(summary)
        for priority in SemanticMediaPriority.allCases {
            summary.priority = priority
            if priority == .image { encoder.release() }
            progress(summary)
            var after = ""
            while true {
                let paths = try store.candidates(priority, after: after)
                if paths.isEmpty { break }
                for path in paths {
                    try waitWhilePaused(paused, cancelled: cancelled)
                    do {
                        let indexed = try index(path, scope: scope, store: store, reader: reader, encoder: encoder,
                            media: media, cancelled: cancelled, waitForIdle: {
                                if !idle() {
                                    summary.waitingForIdle = true; progress(summary)
                                    while !idle() {
                                        if cancelled() { throw CancellationError() }
                                        Thread.sleep(forTimeInterval: 0.25)
                                    }
                                    summary.waitingForIdle = false; progress(summary)
                                }
                                if cancelled() { throw CancellationError() }
                            })
                        if indexed { summary.files += 1 } else { summary.skipped += 1 }
                    } catch let error as SemanticFileStore.Failure { throw error } catch let Failure.inference(error) {
                        throw error
                    } catch let error as SemanticMediaFailure { throw error } catch {
                        if cancelled() { throw CancellationError() }
                        try? store.remove(path); summary.skipped += 1
                    }
                    summary.processed += 1
                    if summary.processed.isMultiple(of: 10) { progress(summary) }
                }
                after = paths.last!
            }
        }
        try waitWhilePaused(paused, cancelled: cancelled)
        if summary.skipped == 0 { try store.pruneDiscovered(cancelled: cancelled) }
        progress(summary)
        return summary
    }

    /// Reconcile changed files without walking the search roots again.
    // swiftlint:disable:next function_parameter_count cyclomatic_complexity
    static func reconcile(paths: [String], scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                          encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)? = nil,
                          idle: () -> Bool = { true }, paused: () -> Bool = { false }, cancelled: () -> Bool,
                          progress: (Summary) -> Void) throws -> Summary {
        let paths = Array(Set(paths)).sorted()
        var summary = Summary()
        summary.total = paths.count
        progress(summary)
        for priority in SemanticMediaPriority.allCases {
            summary.priority = priority
            if priority == .image { encoder.release() }
            for path in paths where SemanticMediaPriority.of(path) == priority {
                try waitWhilePaused(paused, cancelled: cancelled)
                do {
                    let indexed = try index(path, scope: scope, store: store, reader: reader, encoder: encoder,
                                            media: media, cancelled: cancelled, waitForIdle: {
                                                if !idle() {
                                                    summary.waitingForIdle = true; progress(summary)
                                                    while !idle() {
                                                        if cancelled() { throw CancellationError() }
                                                        Thread.sleep(forTimeInterval: 0.25)
                                                    }
                                                    summary.waitingForIdle = false; progress(summary)
                                                }
                                                if cancelled() { throw CancellationError() }
                                            })
                    if indexed { summary.files += 1 } else { summary.skipped += 1 }
                } catch let error as SemanticFileStore.Failure { throw error } catch let Failure.inference(error) {
                    throw error
                } catch let error as SemanticMediaFailure { throw error } catch {
                    if cancelled() { throw CancellationError() }
                    try? store.remove(path); summary.skipped += 1
                }
                summary.processed += 1
                progress(summary)
            }
        }
        try waitWhilePaused(paused, cancelled: cancelled)
        return summary
    }

    private static func waitWhilePaused(_ paused: () -> Bool, cancelled: () -> Bool) throws {
        while paused() {
            if cancelled() { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if cancelled() { throw CancellationError() }
    }

    // swiftlint:disable:next function_parameter_count cyclomatic_complexity
    private static func index(_ path: String, scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                              encoder: SemanticEmbedding, media: (any SemanticMediaEmbedding)?, cancelled: () -> Bool,
                              waitForIdle: () throws -> Void) throws -> Bool {
        let metadata = try reader.read(
            .init(operation: .content, path: path, scope: scope, readText: false),
            isCancelled: cancelled
        )
        guard metadata.error == nil, let modified = metadata.modified, let bytes = metadata.fileSize else {
            try store.remove(path); return false
        }
        if try store.unchanged(path: path, modified: modified, bytes: bytes) {
            return true
        }
        if SemanticMediaPriority.of(path) != .document {
            guard let media else { return false }
            return try indexMedia(path, metadata: metadata, scope: scope, store: store, reader: reader,
                                  media: media, cancelled: cancelled, waitForIdle: waitForIdle)
        }
        let contents = try reader.read(.init(operation: .content, path: path, scope: scope), isCancelled: cancelled)
        guard contents.error == nil, contents.modified == modified, contents.fileSize == bytes,
              let pages = contents.pages else {
            try store.remove(path); return false
        }
        let chunks = SemanticChunk.make(pages)
        guard !chunks.isEmpty else { try store.remove(path); return false }
        var vectors: [[Float]] = []
        let title = String(path.split(separator: "/").last ?? "").prefix(80)
        for start in stride(from: 0, to: chunks.count, by: 8) {
            if cancelled() {
                throw CancellationError()
            }
            let texts = chunks[start ..< min(start + 8, chunks.count)].map { "title: \(title) | text: " + $0.text }
            do { vectors += try encoder.embed(texts, cancelled: cancelled) } catch { throw Failure.inference(error) }
        }
        if cancelled() {
            throw CancellationError()
        }
        // A file changed during inference must never commit the old content.
        let after = try reader.read(
            .init(operation: .content, path: path, scope: scope, readText: false),
            isCancelled: cancelled
        )
        guard after.error == nil, after.modified == modified, after.fileSize == bytes else {
            try store.remove(path); return false
        }
        try store.replace(path: path, modified: modified, bytes: bytes, chunks: chunks, vectors: vectors)
        return true
    }
}
