import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic index processing details", .serialized)
struct SemanticIndexDetailsTests {
    @Test func `pending files show size and completed files retain processing time`() throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try "first document".write(to: first, atomically: true, encoding: .utf8)
        try "second document".write(to: second, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let store = try SemanticFileStore(url: databaseURL)
        _ = try store.discover([(first.path, .document), (second.path, .document)])

        let waiting = try store.processingPage(.pending, offset: 0, limit: 1)
        #expect(waiting.total == 2)
        #expect(waiting.items.count == 1)
        #expect(waiting.items[0].bytes == Int64("first document".utf8.count))
        #expect(waiting.items[0].modified != nil)
        #expect(try store.processingPage(.pending, offset: 1, limit: 1).items.count == 1)

        let reader = SemanticFixtureReader(path: first.path)
        reader.directoryEntries = [first, second].map {
            .init(path: $0.path, kind: .file, modified: reader.modified)
        }
        var current: [String] = []
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store,
                                        reader: reader,
                                        encoder: SemanticFixtureEncoder(), cancelled: { false },
                                        progress: { _ in }, current: { if let path = $0 { current.append(path) } })
        #expect(current.contains(first.path))
        let done = try store.processingPage(.completed, offset: 0, limit: 50)
        #expect(done.total == 2)
        #expect(done.items.allSatisfy { $0.state == "done" && ($0.processingSeconds ?? 0) > 0 })
        #expect(done.items.allSatisfy { $0.completedAt != nil })
        #expect(try store.processingPage(.pending, offset: 0).total == 0)

        let reopened = try SemanticFileStore(url: databaseURL)
        #expect(try reopened.processingPage(.completed, offset: 0).items.allSatisfy {
            ($0.processingSeconds ?? 0) > 0
        })
    }
}
