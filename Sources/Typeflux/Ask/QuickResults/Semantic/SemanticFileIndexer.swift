import Foundation

enum SemanticFileIndexer {
    struct Summary: Equatable, Sendable {
        var files = 0
        var skipped = 0
        var limited = false
        var scanned = 0
        var discovered = 0
        var total: Int?
        var processed = 0
    }
    private enum Failure: Error { case inference(Error) }
    private static let maximumFilesPerRoot = 50_000

    // Reconcile metadata on launch/FSEvents; only changed files need extraction and embedding.
    // Partial scans never remove entries. Search rechecks permissions and file presence.
    // Keep scan failures and cancellation beside the visit callback that stops traversal.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func run(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                    encoder: SemanticEmbedding, cancelled: () -> Bool,
                    progress: (Summary) -> Void) throws -> Summary {
        var seen = Set<String>(), summary = Summary()
        var failure: Error?
        var total = 0
        // Count supported files first so indexing can show a measured completion percentage.
        for root in scope.roots {
            var eligibleFiles = 0
            let visited = AskFileCrawler.crawl(root, scope: scope, reader: reader,
                                               isCancelled: cancelled, visit: { entry in
                                                   summary.scanned += 1
                                                   if entry.kind == .file, SemanticFilePolicy.allows(entry.path) {
                                                       guard eligibleFiles < maximumFilesPerRoot else {
                                                           summary.limited = true
                                                           return false
                                                       }
                                                       eligibleFiles += 1
                                                       total += 1
                                                       summary.discovered = total
                                                   }
                                                   if summary.scanned.isMultiple(of: 1_000) {
                                                       progress(summary)
                                                   }
                                                   return true
                                               })
            if visited >= AskFileCrawler.maximumEntries { summary.limited = true }
            if cancelled() { throw CancellationError() }
            if summary.limited { break }
        }
        let discoveryLimited = summary.limited
        summary.limited = false
        summary.total = total
        progress(summary)
        for root in scope.roots {
            var eligibleFiles = 0
            let visited = AskFileCrawler.crawl(root, scope: scope, reader: reader,
                                               isCancelled: cancelled, skipped: { _, _ in summary.skipped += 1 },
                                               visit: { entry in
                                                   guard !cancelled() else { return false }
                                                   guard entry.kind == .file,
                                                         SemanticFilePolicy.allows(entry.path) else { return true }
                                                   guard eligibleFiles < maximumFilesPerRoot else {
                                                       summary.limited = true
                                                       return false
                                                   }
                                                   eligibleFiles += 1
                                                   do {
                                                       if try self.index(
                                                           entry.path,
                                                           scope: scope,
                                                           store: store,
                                                           reader: reader,
                                                           encoder: encoder,
                                                           cancelled: cancelled
                                                       ) {
                                                           seen.insert(entry.path); summary.files += 1
                                                       } else {
                                                           summary.skipped += 1
                                                       }
                                                   } catch SemanticFileStore.Failure.limit {
                                                       summary.limited = true
                                                       return false
                                                   } catch let Failure.inference(error) {
                                                       failure = error
                                                       return false
                                                   } catch {
                                                       if cancelled() {
                                                           return false
                                                       }
                                                       try? store.remove(entry.path); summary.skipped += 1
                                                   }
                                                   summary.processed += 1
                                                   if summary.processed.isMultiple(of: 10) { progress(summary) }
                                                   return true
                                               })
            if visited >= AskFileCrawler.maximumEntries {
                summary.limited = true
            }
            if cancelled() {
                throw CancellationError()
            }
            if let failure {
                throw failure
            }
            if summary.limited {
                break
            }
        }
        summary.limited = summary.limited || discoveryLimited
        if summary.skipped == 0, !summary.limited {
            try store.prune(keeping: seen, cancelled: cancelled)
        }
        progress(summary)
        return summary
    }

    // swiftlint:disable:next function_parameter_count
    private static func index(_ path: String, scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                              encoder: SemanticEmbedding, cancelled: () -> Bool) throws -> Bool {
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
