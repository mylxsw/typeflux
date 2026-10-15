import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class RestrictedScanReader: AskFileReading {
    let reader = AskFileReader()
    var restricted = ""
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try reader.read(request, isCancelled: isCancelled)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        if request.operation == .directory, request.path == restricted {
            _ = receive(.init(error: EACCES)); return
        }
        try reader.stream(request, isCancelled: isCancelled, receive: receive)
    }
}

@Suite("Confirmed scan ranges prune all durable state", .serialized)
struct SemanticIndexPruneTests {
    private func stage(_ store: SemanticFileStore, path: String,
                       metadata: AskFileReadResponse? = nil) throws -> String {
        let generation = try store.beginMediaJob(path: path,
                                                 metadata: metadata ?? .init(
                                                     fileSize: 10,
                                                     modified: Date(timeIntervalSince1970: 100)
                                                 ))
        try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                   input: .init(kind: .audio, path: "fixture", time: 0), vector: semanticVector())
        try store.failJob(path, reason: "media-extraction-failed")
        return generation
    }

    private func counts(_ store: SemanticFileStore) throws -> [Int] {
        try store.lock.withLock {
            try ["files", "chunks", "lexical", "jobs", "media_jobs", "media_segments", "work_queue"]
                .map { try store.count($0) }
        }
    }

    @Test func `confirmed deletion prunes multiple batches and rolls back every related table on failure`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for index in 0 ..< 130 {
            let path = root.path + "/deleted-\(index).wav"
            _ = try stage(store, path: path)
            try store.enqueue([(path, .audio)])
        }
        let published = root.path + "/deleted-0.wav"
        try store.replace(path: published, modified: Date(), bytes: 10,
                          chunks: [.init(text: "deletedzebra", page: nil)], vectors: [semanticVector()])
        try store.beginDiscovery(scope: semanticScope(root.path))
        try store.finishDirectory(root.path, failed: false)
        let before = try counts(store)
        #expect(throws: CancellationError.self) { try store.pruneDiscovered(cancelled: { true }) }
        #expect(try counts(store) == before)
        try store.lock.withLock {
            try store
                .sql(
                    "CREATE TRIGGER reject_media_prune BEFORE DELETE ON media_jobs BEGIN SELECT RAISE(ABORT,'injected'); END"
                )
        }
        #expect(throws: SemanticFileStore.Failure.self) { try store.pruneDiscovered(cancelled: { false }) }
        #expect(try counts(store) == before, "a failing batch cannot detach jobs, files or media segments")
        try store.lock.withLock { try store.sql("DROP TRIGGER reject_media_prune") }
        try SemanticFileStore(url: store.url).pruneDiscovered(cancelled: { false })
        #expect(try counts(store) == Array(repeating: 0, count: 7))
    }

    @Test func `permission failure retains unconfirmed checkpoint and queue then resumes without encoding it again`(
    ) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let restricted = root.appendingPathComponent("restricted"), file = restricted.appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        let samples = (0 ..< 16000).map { Float(sin(Double($0) * 0.17) * 0.2) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: file) }
        let scope = semanticScope(root.path), reader = RestrictedScanReader()
        let metadata = try reader.read(
            .init(operation: .content, path: file.path, scope: scope, readText: false),
            isCancelled: { false }
        )
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let generation = try stage(store, path: file.path, metadata: metadata)
        try store.enqueue([(file.path, .audio)])
        // A sibling with the same path prefix must not inherit the failed subtree's protection.
        let sibling = root.path + "/restricted-other/deleted.wav"
        _ = try stage(store, path: sibling)
        reader.restricted = restricted.path
        let media = SemanticFixtureMediaEncoder()
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                        progress: { _ in })
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.job(file.path)?.generation == generation)
        #expect(try reopened.job(file.path)?.reason == "media-extraction-failed")
        #expect(try reopened.hasMediaSegment(path: file.path, generation: generation, ordinal: 0))
        #expect(try reopened.job(sibling) == nil)
        #expect(try reopened.lock.withLock { try reopened.count("work_queue") } == 1)
        #expect(media.calls == 0)
        reader.restricted = ""
        _ = try SemanticFileIndexer.run(scope: scope, store: reopened, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                        progress: { _ in })
        #expect(try reopened.job(file.path)?.state == .done && reopened.job(file.path)?.attempts == 1)
        #expect(try media.calls == 0 && reopened.counts().chunks == 1)
        #expect(try reopened.lock.withLock { try reopened.count("media_jobs") + reopened.count("media_segments") } == 0)
    }

    @Test(arguments: ["deleted", "excluded-subtree", "excluded-root", "removed-root"])
    func `offline deletion and scope revocation remove failed private media`(mode: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let subtree = root.appendingPathComponent("private-media"), file = subtree.appendingPathComponent("old.wav")
        try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        _ = try stage(store, path: file.path)
        var scope = semanticScope(root.path)
        try store.beginDiscovery(scope: scope)
        try store.recordDirectories([subtree.path])
        try store.finishDirectory(subtree.path, failed: true)
        switch mode {
        case "excluded-subtree": scope.excludedPaths = [subtree.path]
        case "excluded-root": scope.excludedPaths = [root.path]
        case "removed-root": scope.roots = []
        default: break
        }
        let reopened = try SemanticFileStore(url: store.url)
        _ = try SemanticFileIndexer.run(scope: scope, store: reopened, reader: AskFileReader(),
                                        encoder: SemanticFixtureEncoder(), cancelled: { false }, progress: { _ in })
        #expect(try counts(reopened) == Array(repeating: 0, count: 7))
    }
}
