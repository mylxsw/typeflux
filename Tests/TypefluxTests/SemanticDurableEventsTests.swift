import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Bounded persistent semantic events", .serialized)
struct SemanticDurableEventsTests {
    @Test func `storm coalesces durably and ignores every owned artifact`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let url = index.appendingPathComponent("index-events.sqlite"), scope = semanticScope(root.path)
        let journal = try SemanticIndexEvents(url: url)
        let events = (0 ..< 10000).map { AskFileChange(
            path: root.path + "/folder-\($0)/note.txt",
            rescan: false,
            isDirectory: false
        ) }
        try journal.append(events, scope: scope, directory: index.path, eventID: 400, cancelled: { false })
        #expect(try journal.queueStatistics().entries <= 128)
        #expect(try journal.queueStatistics().coalesced > 0)
        #expect(try journal.requestNotification()); #expect(try !journal.requestNotification())
        journal.receivedNotification(); #expect(try journal.requestNotification())
        let ignored = [
            "semantic-files.sqlite",
            "semantic-files.sqlite-wal",
            "semantic-files.sqlite-shm",
            "index-events.sqlite",
            "embeddinggemma-2-Q8_0.gguf",
            ".typeflux-media-cache/job/image.jpg"
        ].map {
            AskFileChange(path: index.path + "/" + $0, rescan: true, isDirectory: false, structureChanged: true)
        }
        let ignoredChanged = try journal.append(
            ignored,
            scope: scope,
            directory: index.path,
            eventID: 401,
            cancelled: { false }
        )
        #expect(!ignoredChanged)
        journal.close()
        let recovered = try SemanticIndexEvents(url: url)
        #expect(recovered.eventID >= 401)
        let store = try SemanticFileStore(url: index.appendingPathComponent("semantic-files.sqlite"))
        try recovered.transfer(to: store)
        #expect(try !recovered.pending())
        #expect(try store.nextScanRequest()?.path == root.path)
        #expect(try store.hasQueuedWork())
        recovered.close(); recovered.close()
        #expect(throws: SemanticFileStore.Failure.self) { try recovered.pending() }
    }

    @Test func `nested subtrees merge and acknowledgement cannot erase later changes`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let a = root.path + "/a", b = root.path + "/b"
        try store.acceptEvents([.init(path: a + "/child", subtree: true, revision: 1, root: root.path),
                                .init(path: a, subtree: true, revision: 1, root: root.path)])
        let firstValue = try store.nextScanRequest()
        let first = try #require(firstValue)
        #expect(first.path == a)
        try store.acceptEvents([.init(path: a + "/another", subtree: true, revision: 2, root: root.path)])
        try store.finishScanRequest(first)
        let secondValue = try store.nextScanRequest()
        let second = try #require(secondValue)
        #expect(second.path == a && second.revision != first.revision)
        try store.finishScanRequest(second)
        try store.acceptEvents([.init(path: b + "/note.txt", subtree: false, revision: 3, root: root.path)])
        #expect(try store.nextWork(.document) == b + "/note.txt")
        for i in 0 ..< 130 {
            try store.acceptEvents([.init(
                path: root.path + "/tree-\(i)",
                subtree: true,
                revision: Int64(i),
                root: root.path
            )])
        }
        #expect(try store.nextScanRequest()?.path == root.path)
        #expect(try store.lock.withLock { try store.count("scan_requests") } == 1)
    }

    @Test func `cancelled append never acknowledges unwritten events`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SemanticIndexEvents(url: root.appendingPathComponent("events.sqlite"))
        let prior = journal.eventID
        #expect(throws: CancellationError.self) {
            try journal.append([.init(path: root.path + "/a.txt", rescan: false)], scope: semanticScope(root.path),
                               directory: root.path + "/state", eventID: prior + 1, cancelled: { true })
        }
        #expect(try journal.eventID == prior && (journal.queueStatistics().entries) == 0)
    }
}
