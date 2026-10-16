import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Index work diagnostics", .serialized)
struct SemanticIndexDiagnosticsTests {
    @Test func `unchanged startup and single-file events encode only necessary content`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try "first unique body".write(to: a, atomically: true, encoding: .utf8)
        try "second unique body".write(to: b, atomically: true, encoding: .utf8)
        let state = root.appendingPathComponent("state"); try FileManager.default.createDirectory(
            at: state,
            withIntermediateDirectories: true
        )
        let store = try SemanticFileStore(url: state.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(), encoder = SemanticFixtureEncoder(), scope = semanticScope(root.path)
        #expect(try store.runDiagnostics() == nil)
        try store.beginRun(reason: .startup, configuration: root.path)
        _ = try SemanticFileIndexer.run(
            scope: scope,
            store: store,
            reader: reader,
            encoder: encoder,
            cancelled: { false },
            progress: { _ in }
        )
        try store.finishRun(stage: .complete)
        let firstValue = try store.runDiagnostics()
        let first = try #require(firstValue)
        #expect(first.counters["vectorsPublished"] == 2 && first.counters["vectorsInferred"] == 2)
        #expect(first.stage == .complete && first.finished != nil)
        let before = encoder.calls
        try store.beginRun(reason: .resume, configuration: root.path)
        _ = try SemanticFileIndexer.run(
            scope: scope,
            store: store,
            reader: reader,
            encoder: encoder,
            cancelled: { false },
            progress: { _ in }
        )
        #expect(encoder.calls == before)
        #expect(try store.runDiagnostics()?.counters["metadataReused"] == 2)
        try "new changed body".write(to: a, atomically: true, encoding: .utf8)
        try store.beginRun(reason: .filesystem, configuration: root.path)
        _ = try SemanticFileIndexer.reconcile(
            paths: [a.path],
            scope: scope,
            store: store,
            reader: reader,
            encoder: encoder,
            cancelled: { false },
            progress: { _ in }
        )
        try store.updateBudget(.init(yields: 4, milliseconds: 120, interruptions: 2), since: .init())
        try store.finishRun(stage: .complete)
        let changedValue = try store.runDiagnostics()
        let changed = try #require(changedValue)
        #expect(encoder.calls == before + 1)
        #expect(changed.counters["vectorsPublished"] == 1 && changed.counters["extractionBatches"] == 1)
        #expect(changed.counters["budgetYields"] == 4 && changed.counters["budgetInterruptions"] == 2)
        #expect(changed.id != first.id && changed.configurationGeneration == first.configurationGeneration)
        let text = try String(decoding: JSONEncoder().encode(changed), as: UTF8.self)
        #expect(!text.contains(root.path) && !text.contains("changed body") && !text.contains("a.txt"))
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.runDiagnostics() == changed)
        for _ in 0 ..< 35 {
            try store.beginRun(reason: .retry, configuration: "other")
        }
        #expect(try store.lock.withLock { try store.count("index_runs") } == 32)
        #expect(try store.runDiagnostics()?.configurationGeneration != first.configurationGeneration)
    }

    @Test func `subtree pruning never removes another completed subtree`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let first = root.path + "/first", second = root.path + "/second"
        for path in [first + "/gone.txt", second + "/keep.txt"] {
            try store.replace(
                path: path,
                modified: Date(),
                bytes: 1,
                chunks: [.init(text: "body", page: nil)],
                vectors: [semanticVector()]
            )
        }
        try store.beginDiscovery(scope: semanticScope(root.path), roots: [first])
        try store.finishDirectory(first, failed: false)
        try store.pruneDiscovered(cancelled: { false })
        #expect(try store.counts().files == 1)
        #expect(try store.lexicalSearch(text: "body", query: .init("body"), type: .all, scope: semanticScope(root.path),
                                        limit: 5, cancelled: { false }).map(\.path) == [second + "/keep.txt"])
    }
}
