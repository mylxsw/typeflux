import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Semantic indexing without directory or database quotas", .serialized)
struct SemanticFileCapacityTests {
    @Test func largeDirectoryContinuesIntoNestedFoldersAndLaterRoots() throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticLargeDirectoryReader(root: root.path)
        let encoder = SemanticFixtureEncoder()
        var scope = semanticScope(root.path)
        scope.roots = [root.path + "/large", root.path + "/second"]
        func run(cancelled: () -> Bool = { false }) throws -> SemanticFileIndexer.Summary {
            try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
                                        cancelled: cancelled, progress: { _ in })
        }
        let result = try run()
        #expect(result.files == 3 && result.skipped == 0)
        #expect(reader.emitted > 50_000)
        #expect(reader.paths == [scope.roots[0], scope.roots[0] + "/nested", scope.roots[1]])
        #expect(reader.limits.allSatisfy { $0 == nil }, "no fallback to the filename index's entry quota")
        #expect(reader.maximumBatch <= 128, "large directories still arrive in bounded frames")
        #expect(try store.counts().files == 3)
        #expect(encoder.calls == 3)

        reader.emitted = 0
        #expect(throws: CancellationError.self) { try run(cancelled: { reader.emitted >= 50_000 }) }
        #expect(try store.counts().files == 3, "cancellation never prunes unvisited documents")
        reader.emitted = 0
        #expect(try run().files == 3)
        #expect(encoder.calls == 3, "resuming reuses completed embeddings")
    }

    @Test func existingHundredThousandChunksAcceptMoreDocumentsAndRemainSearchable() throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let date = Date(timeIntervalSince1970: 100)
        try store.replace(path: root.path + "/existing.txt", modified: date, bytes: 10,
                          chunks: [.init(text: "fixture", page: nil)], vectors: [semanticVector(1)])
        // Seed a real, compatible index at the old quota without invoking a model 100,000 times.
        try self.execute(store, """
        BEGIN IMMEDIATE;
        WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM numbers WHERE n < 99999)
        INSERT INTO chunks(path,text,page,vector)
        SELECT c.path,c.text,c.page,c.vector FROM chunks c CROSS JOIN numbers WHERE c.id=1;
        INSERT INTO lexical(rowid,terms) SELECT id,'fixture' FROM chunks WHERE id>1;
        COMMIT;
        """)
        #expect(try store.counts().chunks == 100_000)
        let path = root.path + "/new-document.md"
        try store.replace(path: path, modified: date, bytes: 20,
                          chunks: [.init(text: "reimbursement", page: 2)], vectors: [semanticVector()])
        #expect(try store.counts().chunks == 100_001)
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.unchanged(path: path, modified: date, bytes: 20))
        let started = ContinuousClock.now
        let hits = try reopened.search(vector: semanticVector(), text: "reimbursement", query: .init("reimbursement"),
                                       type: .all, scope: semanticScope(root.path), limit: 1, cancelled: { false })
        print("Exact vector + lexical query across 100,001 chunks: \(started.duration(to: .now))")
        #expect(hits.map(\.path) == [path])
        #expect(hits.first?.evidence?.page == 2)
    }

    @Test func storageFailureIsReportedAndKeepsThePreviouslyCommittedFile() throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticFixtureReader(path: root.path + "/notes.md")
        let encoder = SemanticFixtureEncoder()
        let previous = reader.modified.addingTimeInterval(-1)
        try store.replace(path: reader.path, modified: previous, bytes: 20,
                          chunks: [.init(text: "previous", page: nil)], vectors: [semanticVector()])
        try self.execute(store, """
        CREATE TRIGGER simulate_full_disk BEFORE INSERT ON files BEGIN
        SELECT RAISE(FAIL,'simulated storage failure'); END;
        """)
        #expect(throws: SemanticFileStore.Failure.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: encoder, cancelled: { false }, progress: { _ in })
        }
        #expect(try store.unchanged(path: reader.path, modified: previous, bytes: 20))
        #expect(try store.counts().chunks == 1)
        try self.execute(store, "DROP TRIGGER simulate_full_disk")
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(result.files == 1)
        #expect(try store.unchanged(path: reader.path, modified: reader.modified, bytes: 20))
    }

    private func execute(_ store: SemanticFileStore, _ sql: String) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(store.url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
}

/// Produces a large scope lazily; never touches the user's filesystem or needs model weights.
private final class SemanticLargeDirectoryReader: AskFileReading {
    let root: String
    var paths: [String] = []
    var limits: [Int?] = []
    var maximumBatch = 0
    var emitted = 0
    init(root: String) { self.root = root }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() { throw CancellationError() }
        return .init(fileSize: 20, modified: Date(timeIntervalSince1970: 100),
                     pages: request.readText ? [.init(text: "reimbursement")] : nil)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        paths.append(request.path); limits.append(request.limit)
        let large = request.path == self.root + "/large"
        let count = min(request.limit ?? Int.max, large ? 50_102 : 1)
        for start in stride(from: 0, to: count, by: 128) {
            if isCancelled() { throw CancellationError() }
            let entries = (start ..< min(start + 128, count)).map { index in
                let folder = large && index == 50_101
                let name = folder ? "nested" : (large && index < 50_100 ? "vector-\(index).svg" : "late.md")
                return AskFileCrawler.Entry(path: request.path + "/" + name, kind: folder ? .folder : .file,
                                            modified: Date(timeIntervalSince1970: 100))
            }
            self.emitted += entries.count; self.maximumBatch = max(self.maximumBatch, entries.count)
            if !receive(.init(entries: entries, more: start + entries.count < count)) { return }
        }
    }
}
