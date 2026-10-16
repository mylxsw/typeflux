import Foundation
import Testing
@testable import Typeflux

private final class PausingDirectoryReader: AskFileReading, @unchecked Sendable {
    let root: String
    let gate: SemanticIndexPauseGate

    init(root: String, gate: SemanticIndexPauseGate) {
        self.root = root
        self.gate = gate
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        .init()
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        let modified = Date(timeIntervalSince1970: 100)
        let first = AskFileCrawler.Entry(path: root + "/first.txt", kind: .file, modified: modified)
        let second = AskFileCrawler.Entry(path: root + "/second.txt", kind: .file, modified: modified)
        guard receive(.init(entries: [first], more: true)) else { return }
        gate.setPaused(true)
        _ = receive(.init(entries: [second], more: false))
    }
}

@Suite("Semantic discovery pause", .serialized)
struct SemanticDiscoveryPauseTests {
    @Test func `pause stops a directory stream between frames and resumes without losing files`() async throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let gate = SemanticIndexPauseGate()
        let reader = PausingDirectoryReader(root: root.path, gate: gate)
        let work = Task.detached {
            var summary = SemanticFileIndexer.Summary()
            try SemanticFileIndexer.discover(scope: semanticScope(root.path), store: store, reader: reader,
                                             paused: { gate.isPaused }, cancelled: { false },
                                             summary: &summary, progress: { _ in })
            return summary
        }
        defer { gate.setPaused(false); work.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.isPaused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.isPaused)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try store.lock.withLock { try store.count("discovery") } == 1)
        #expect(try store.nextDirectory() == root.path)

        gate.setPaused(false)
        let summary = try await work.value
        #expect(summary.scanned == 2)
        #expect(try store.lock.withLock { try store.count("discovery") } == 2)
        #expect(try store.nextDirectory() == nil)
    }
}
