import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic inference isolation")
struct SemanticEmbeddingWorkerTests {
    func script(_ contents: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func `validated vectors and malformed helper responses`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let vector = semanticVector()
        let json = try "{\"entries\":[],\"embeddings\":" + String(decoding: JSONEncoder().encode([vector]), as: UTF8.self) + "}"
        let source = try script("while IFS= read -r line; do printf '%s\\n' '" + json + "'; done\n", in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source)
        #expect(try worker.embed(["document"], cancelled: { false }) == [vector])
        #expect(try await worker.query("query", lifecycle: AskSearchCancellation()) == vector)
        #expect(throws: SemanticFileStore.Failure.self) { try worker.embed(["one", "two"], cancelled: { false }) }
        #expect(throws: CancellationError.self) { try worker.embed(["document"], cancelled: { true }) }
        worker.stop()
        for response in ["{\"entries\":[],\"error\":22}", "{\"entries\":[],\"embeddings\":[[0]]}", "broken-json"] {
            let file = try script("read line; printf '%s\\n' '" + response + "'\n", in: root)
            let invalid = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file)
            #expect(throws: (any Error).self) { try invalid.embed(["document"], cancelled: { false }) }
        }
        let idle = try script("read first; read second\n", in: root)
        let blocked = SemanticEmbeddingWorker(
            helper: URL(fileURLWithPath: "/bin/sh"),
            model: idle,
            timeout: 0.05,
            startupTimeout: 0.05
        )
        #expect(throws: AskFileReadError.self) { try blocked.embed(["document"], cancelled: { false }) }
    }

    @Test func realModelUsesTheApplicationIPCWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] else { return }
        let helper = SemanticModel.helperURL
        #expect(FileManager.default.isExecutableFile(atPath: helper.path), "Build the optional helper first")
        let worker = SemanticEmbeddingWorker(helper: helper, model: URL(fileURLWithPath: path))
        let vector = try await worker.query("项目费用报销需要什么？", lifecycle: AskSearchCancellation())
        #expect(SemanticFileStore.valid(vector))
        worker.stop()
    }

    @Test func idleReleaseRewarmsTheHelperWhileRetainingQueryVectors() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let starts = root.appendingPathComponent("starts"), calls = root.appendingPathComponent("calls")
        let vector = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        let source = try script("""
        printf x >> '\(starts.path)'
        while IFS= read -r line; do
          printf x >> '\(calls.path)'
          printf '%s\\n' '{"entries":[],"embeddings":\(vector)}'
        done
        """, in: root)
        // Exercise the production DispatchQueue timer with a shorter idle period.
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source,
                                             idleTimeout: 0.1)
        defer { worker.stop() }
        let lifecycle = AskSearchCancellation()
        func count(_ file: URL) -> Int { (try? Data(contentsOf: file).count) ?? 0 }
        try await worker.prepare(lifecycle: lifecycle)
        _ = try await worker.query("cached", lifecycle: lifecycle)
        #expect(count(starts) == 1 && count(calls) == 2)
        try await Task.sleep(for: .milliseconds(250))
        _ = try await worker.query("cached", lifecycle: lifecycle)
        #expect(count(starts) == 1 && count(calls) == 2, "idle release retains ordinary cached vectors")
        try await worker.prepare(lifecycle: lifecycle)
        #expect(count(starts) == 2 && count(calls) == 3, "preparation must reload after idle release")
        _ = try await worker.query("uncached", lifecycle: lifecycle)
        try await worker.prepare(lifecycle: lifecycle)
        #expect(count(starts) == 2 && count(calls) == 4, "new queries and repeated preparation reuse the helper")
        lifecycle.cancel()
        await #expect(throws: CancellationError.self) { try await worker.prepare(lifecycle: lifecycle) }
        #expect(count(calls) == 4)
        worker.stop()
        try await worker.prepare(lifecycle: AskSearchCancellation())
        #expect(count(starts) == 3 && count(calls) == 5, "voice stop invalidates the epoch and warmup cache")
    }

    @Test func `same query coalesces and cancelled typing keeps the warm helper`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let starts = root.appendingPathComponent("starts"), calls = root.appendingPathComponent("calls")
        let vector = try String(decoding: JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        let source = try script("""
        printf x >> '\(starts.path)'
        while IFS= read -r line; do
          printf x >> '\(calls.path)'
          sleep 0.15
          printf '%s\\n' '{"entries":[],"embeddings":\(vector)}'
        done
        """, in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source)
        let lifecycle = AskSearchCancellation()
        func count(_ file: URL) -> Int {
            (try? Data(contentsOf: file).count) ?? 0
        }
        let first = Task { try await worker.query("obsolete", lifecycle: lifecycle) }
        let deadline = ContinuousClock.now + .seconds(3)
        while count(calls) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(count(calls) == 1)
        first.cancel()
        let second = Task { try await worker.query("latest", lifecycle: lifecycle) }
        let duplicate = Task { try await worker.query("latest", lifecycle: lifecycle) }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == semanticVector())
        #expect(try await duplicate.value == semanticVector())
        #expect(count(calls) == 2 && count(starts) == 1)
        #expect(try await worker.query("latest", lifecycle: lifecycle) == semanticVector())
        #expect(count(calls) == 2)
        worker.stop()
    }

    @Test func `only latest pending query runs and failed inference is not replayed`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls"), marker = root.appendingPathComponent("restarted")
        let vector = try String(decoding: JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        let source = try script("""
        if [ ! -e '\(marker.path)' ]; then
          touch '\(marker.path)'
          read line
          exit 1
        fi
        while IFS= read -r line; do
          printf x >> '\(calls.path)'
          sleep 0.4
          printf '%s\\n' '{"entries":[],"embeddings":\(vector)}'
        done
        """, in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source,
                                             timeout: 5, startupTimeout: 5)
        let lifecycle = AskSearchCancellation()
        let launched = AskSearchCancellation()
        let trace = SemanticSearchTrace(sink: { if $0.stage == "helper-launch" { launched.cancel() } })
        await #expect(throws: (any Error).self) {
            try await SemanticSearchTrace.$current.withValue(trace) {
                try await worker.query("recover", lifecycle: lifecycle)
            }
        }
        #expect(launched.isCancelled && !FileManager.default.fileExists(atPath: calls.path))
        // Only a new explicit caller operation can restart the helper.
        #expect(try await worker.query("explicit", lifecycle: lifecycle) == semanticVector())
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let active = Task { try await worker.query("active", lifecycle: lifecycle) }
        let deadline = ContinuousClock.now + .seconds(3)
        while ((try? Data(contentsOf: calls).count) ?? 0) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        var tasks: [Task<[Float], Error>] = []
        for index in 0 ..< 20 {
            let accepted = AskSearchCancellation()
            let trace = SemanticSearchTrace(sink: { event in
                if event.stage == "helper-enqueued" { accepted.cancel() }
            })
            tasks.append(Task {
                try await SemanticSearchTrace.$current.withValue(trace) {
                    try await worker.query("typing-\(index)", lifecycle: lifecycle)
                }
            })
            let until = ContinuousClock.now + .seconds(2)
            while !accepted.isCancelled, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
            #expect(accepted.isCancelled)
        }
        let latest = Task { try await worker.query("final", lifecycle: lifecycle) }
        _ = try await active.value
        for task in tasks {
            _ = try? await task.value
        }
        #expect(try await latest.value == semanticVector())
        #expect(((try? Data(contentsOf: calls).count) ?? 0) <= 4)
        lifecycle.cancel()
        await #expect(throws: CancellationError.self) { try await worker.query("cancelled", lifecycle: lifecycle) }
        worker.stop()
        let broken = try script("read line; exit 1\n", in: root)
        let failed = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: broken,
                                             timeout: 0.05, startupTimeout: 0.05)
        await #expect(throws: (any Error).self) { try await failed.query("failure", lifecycle: AskSearchCancellation())
        }
        failed.stop()
    }
    @Test func stoppingForVoiceCancelsQueuedWorkAndAllowsALaterRestart() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls")
        let vector = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        let source = try script("""
        while IFS= read -r line; do
          printf x >> '\(calls.path)'
          sleep 0.15
          printf '%s\\n' '{"entries":[],"embeddings":\(vector)}'
        done
        """, in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source)
        let lifecycle = AskSearchCancellation()
        let active = Task { try await worker.query("active", lifecycle: lifecycle) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: calls.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = Task { try await worker.query("pending", lifecycle: lifecycle) }
        try await Task.sleep(for: .milliseconds(10))
        worker.stop()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await worker.query("later", lifecycle: lifecycle) == semanticVector())
        #expect(try Data(contentsOf: calls).count == 2)
        worker.stop()
    }

}
