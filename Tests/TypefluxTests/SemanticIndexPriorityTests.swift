import Foundation
import Testing
@testable import Typeflux

private final class SemanticBatchProbe: SemanticEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let gate: SemanticIndexPauseGate
    var calls: Int { lock.withLock { count } }
    init(gate: SemanticIndexPauseGate) { self.gate = gate }
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        let call = lock.withLock { count += 1; return count }
        if call == 1 { gate.beginQuery() }
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Query priority at background batch boundaries", .serialized)
struct SemanticIndexPriorityTests {
    @Test func documentEncodingYieldsAfterTheCurrentBatchAndResumesWithoutRestarting() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = SemanticIndexPauseGate(), token = AskSearchCancellation(), encoder = SemanticBatchProbe(gate: gate)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let task = Task.detached {
            let reader = SemanticFixtureReader(path: root.path + "/long-document.txt")
            reader.text = String(repeating: "document contents ", count: 1000)
            return try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, paused: { gate.isPaused }, cancelled: { token.isCancelled }, progress: { _ in })
        }
        defer { token.cancel(); gate.endQuery() }
        let deadline = ContinuousClock.now + .seconds(3)
        while encoder.calls == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(encoder.calls == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(encoder.calls == 1, "the next background batch waits while a query owns priority")
        gate.endQuery()
        let result = try await task.value
        #expect(result.files == 1 && encoder.calls > 1)
        #expect(try store.counts().files == 1)
        gate.beginQuery(); gate.beginQuery(); gate.endQuery()
        #expect(gate.isPaused)
        gate.endQuery(); gate.endQuery()
        #expect(!gate.isPaused)
    }
}
