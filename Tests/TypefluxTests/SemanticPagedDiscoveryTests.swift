import Foundation
import Testing
@testable import Typeflux

@Suite("Directory checkpoints bound each worker turn", .serialized)
struct SemanticPagedDiscoveryTests {
    @Test func `filtered names count toward pages and worker loss replays only the active directory`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0 ..< 350 {
            try Data().write(to: root.appendingPathComponent("\(i).txt"))
        }
        let scope = semanticScope(root.path), session = AskDirectorySession(), mounts = AskFileMounts(excluded: [])
        var request = AskFileReadRequest(operation: .directory, path: root.path, scope: scope, directoryCursor: .init())
        let first = session.page(request, scope: scope, mounts: mounts)
        #expect(first.inspected == 128 && first.entries.count <= 128)
        let cursor = try #require(first.directoryCursor)
        request.directoryCursor = cursor
        let replay = AskDirectorySession().page(request, scope: scope, mounts: mounts)
        #expect(replay.directoryCursor?.session != cursor.session)
        #expect(replay.entries.map(\.path) == first.entries.map(\.path))
        var found = Set(first.entries.map(\.path)), pages = 1
        while request.directoryCursor != nil {
            let response = session.page(request, scope: scope, mounts: mounts)
            #expect((response.inspected ?? 0) <= 128)
            found.formUnion(response.entries.map(\.path)); request.directoryCursor = response.directoryCursor
            pages += 1; try #require(pages < 6)
        }
        #expect(found.count == 350 && pages == 3)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.beginDiscovery(scope: scope)
        try store.checkpointDirectory(root.path, cursor: cursor)
        #expect(try SemanticFileStore(url: store.url).directoryCursor(root.path) == cursor)
        try store.checkpointDirectory(root.path, cursor: nil)
        #expect(try store.directoryCursor(root.path).session.isEmpty)
    }
}

@Suite("Coalesced index progress delivery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticIndexProgressRelayTests {
    @Test func `only the latest pending progress reaches UI and close rejects stale work`() async throws {
        var values: [Int] = []
        let relay = SemanticIndexProgressRelay { values.append($0.scanned) }
        for i in 0 ..< 10000 {
            relay.send(.init(scanned: i))
        }
        try await Task.sleep(for: .milliseconds(220))
        #expect(values == [9999])
        relay.send(.init(scanned: 10000)); relay.close()
        try await Task.sleep(for: .milliseconds(220))
        #expect(values == [9999])
    }

    @Test func optionalDownloadProgressKeepsTheFinalNilAndRemainsBounded() async throws {
        var values: [Double?] = []
        let relay = SemanticProgressRelay<Double?> { values.append($0) }
        for _ in 0 ..< 10000 {
            relay.send(0.5)
        }
        relay.send(nil)
        try await Task.sleep(for: .milliseconds(220))
        #expect(values.count == 1 && values[0] == nil)
        relay.close(); relay.send(1)
        try await Task.sleep(for: .milliseconds(220))
        #expect(values.count == 1)
    }
}

@Suite("Bounded vector snapshots", .serialized)
struct SemanticBoundedSnapshotTests {
    @Test func `streamed and cached pages rank identically and pressure releases resident data`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let path = root.path + "/book.txt", other = root.path + "/other.txt"
        try store.replace(path: path, modified: Date(), bytes: 100,
                          chunks: (0 ..< 600).map { .init(text: "chapter \($0)", page: $0) },
                          vectors: Array(repeating: semanticVector(), count: 600))
        try store.replace(
            path: other,
            modified: Date(),
            bytes: 1,
            chunks: [.init(text: "noise", page: nil)],
            vectors: [semanticVector(1)]
        )
        let cached = try SemanticVectorReader(url: store.url, cacheLimit: 1024 * 1024)
        let streamed = try SemanticVectorReader(url: store.url, cacheLimit: 0)
        func hits(_ reader: SemanticVectorReader) throws -> [AskFileHit] {
            try reader.search(vector: semanticVector(), text: "unseen", query: .init("unseen"), type: .all,
                              scope: semanticScope(root.path), limit: 5, cancelled: { false })
        }
        #expect(try hits(cached).map(\.path) == hits(streamed).map(\.path))
        #expect(cached.residentBytes <= 1024 * 1024 && cached.residentBytes > 0)
        #expect(streamed.residentBytes == 0)
        cached.releaseMemory()
        #expect(cached.residentBytes == 0)
        #expect(try hits(cached).first?.path == path)
        #expect(cached.residentBytes == 0, "pressure cooldown avoids immediately repopulating pages")
        #expect(throws: CancellationError.self) { try cached.prepare(cancelled: { true }) }
        cached.close(); streamed.close()
        #expect(throws: SemanticFileStore.Failure.self) { try hits(cached) }
    }
}
