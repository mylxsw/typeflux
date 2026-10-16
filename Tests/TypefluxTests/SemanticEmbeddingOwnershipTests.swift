import Darwin
import Foundation
import XCTest
@testable import Typeflux

final class SemanticEmbeddingOwnershipTests: XCTestCase {
    private func script(_ root: URL, response: String? = nil) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString)
        let json = try response ?? "{\"entries\":[],\"embeddings\":\(String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self))}"
        try Data("while IFS= read -r line; do printf '%s\\n' '\(json)'; done\n".utf8).write(to: file)
        return file
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    func testIndependentOwnersKeepBlockedHostAfterCollectionAndFenceLateDelivery() async throws {
        let owners = SemanticEmbeddingOwners(), entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let cancelled = AskSearchCancellation()
        let host = Task.detached {
            try owners.query.perform(cancelled: { cancelled.isCancelled }) {
                entered.cancel()
                guard release.wait(timeout: .now() + 8) == .success else { throw AskFileReadError.timeout }
                return 42
            }
        }
        try await wait { entered.isCancelled }
        defer { release.signal() }
        cancelled.cancel(); owners.stop()
        XCTAssertFalse(owners.query.isIdle)
        XCTAssertThrowsError(try owners.query.perform(cancelled: { false }) { 1 })
        XCTAssertEqual(try owners.indexing.perform(cancelled: { false }) { 2 }, 2)
        XCTAssertEqual(try owners.media.perform(cancelled: { false }) { 3 }, 3)
        do { try await owners.waitUntilIdle(timeout: 0.02); XCTFail("Released blocked host") } catch {}
        release.signal()
        do { _ = try await host.value; XCTFail("Published revoked host result") } catch {}
        try await owners.waitUntilIdle()
        XCTAssertThrowsError(try owners.query.perform(cancelled: { true }) { 4 })
        XCTAssertEqual(try owners.query.perform(cancelled: { false }) { 5 }, 5)
    }
    func testDelayedNativeCollectionPreventsReplacementAndRetainsModelOwnership() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(), collect = AskSearchCancellation()
        let reaper = OwnedProcessReaper(schedulesReaping: false, reaped: { pid in
            guard collect.isCancelled else { return false }
            var status: Int32 = 0; return waitpid(pid, &status, WNOHANG) == pid
        })
        let file = try script(root), scope = AskSearchCancellation()
        let first = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file,
            ownership: owner, lifecycle: scope, reaper: reaper)
        XCTAssertEqual(try first.embed(["private"], cancelled: { false }), [semanticVector()])
        scope.cancel(); first.release()
        XCTAssertFalse(owner.isIdle)
        let next = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file, ownership: owner)
        XCTAssertThrowsError(try next.embed(["new"], cancelled: { false }))
        XCTAssertThrowsError(try first.embed(["old"], cancelled: { false }))
        collect.cancel()
        try await wait { reaper.collectPending(); return owner.isIdle }
        XCTAssertEqual(try next.embed(["explicit"], cancelled: { false }), [semanticVector()])
        next.release(); try await wait { owner.isIdle }
    }
    func testBlockedNativeConsumerKeepsHostLeaseAfterChildCollection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try script(root, response: "{\"entries\":[],\"embeddings\":\(String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)),\"semanticTiming\":{\"encodingMilliseconds\":1}}")
        let owner = SemanticEmbeddingOwnership(), scope = AskSearchCancellation()
        let entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let first = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file,
            ownership: owner, lifecycle: scope)
        let trace = SemanticSearchTrace(sink: { event in
            if event.stage == "model-encode" { entered.cancel(); _ = release.wait(timeout: .now() + 8) }
        })
        let old = Task { try await SemanticSearchTrace.$current.withValue(trace) {
            try await first.query("private", lifecycle: scope)
        } }
        try await wait { entered.isCancelled }
        scope.cancel(); owner.native.stopOwned()
        try await wait { !owner.native.isOccupied }
        XCTAssertFalse(owner.isIdle)
        let next = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file, ownership: owner)
        do { _ = try await next.query("replacement", lifecycle: AskSearchCancellation()); XCTFail("Replaced host") } catch {}
        release.signal()
        do { _ = try await old.value; XCTFail("Returned old vector") } catch {}
        first.stop()
        let nextValue = try await next.query("explicit", lifecycle: AskSearchCancellation())
        XCTAssertEqual(nextValue, semanticVector())
        next.stop(); try await wait { owner.isIdle }
    }
    func testPendingWaitersAreBoundedAndStopDoesNotReplayThem() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(), worker = SemanticEmbeddingWorker(
            helper: URL(fileURLWithPath: "/bin/sh"), model: try script(root), ownership: owner)
        let entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let trace = SemanticSearchTrace(sink: { event in
            if event.stage == "helper-queue-end" { entered.cancel(); _ = release.wait(timeout: .now() + 8) }
        })
        let first = Task { try await SemanticSearchTrace.$current.withValue(trace) {
            try await worker.query("held", lifecycle: AskSearchCancellation())
        } }
        try await wait { entered.isCancelled }
        var pending: [Task<[Float], Error>] = []
        for _ in 0..<SemanticEmbeddingWorker.maximumPending {
            let accepted = AskSearchCancellation()
            let trace = SemanticSearchTrace(sink: { if $0.stage == "helper-enqueued" { accepted.cancel() } })
            pending.append(Task { try await SemanticSearchTrace.$current.withValue(trace) {
                try await worker.query("same", lifecycle: AskSearchCancellation())
            } })
            try await wait { accepted.isCancelled }
        }
        do { _ = try await worker.query("same", lifecycle: AskSearchCancellation()); XCTFail("Unbounded waiter") } catch {}
        worker.stop(); release.signal()
        do { _ = try await first.value; XCTFail("Old query succeeded") } catch {}
        for request in pending { do { _ = try await request.value; XCTFail("Replayed queued request") } catch {} }
        let nextValue = try await worker.query("explicit", lifecycle: AskSearchCancellation())
        XCTAssertEqual(nextValue, semanticVector())
        worker.stop(); try await wait { owner.isIdle }
    }
    func testMediaRefusalMalformedVectorsAndRevokedScopeKeepTruthfulErrors() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for response in [nil, "{\"entries\":[],\"error\":22}", "{\"entries\":[],\"embeddings\":[[0]]}"] {
            let scope = AskSearchCancellation()
            let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: try script(root, response: response), lifecycle: scope)
            let input = SemanticMediaInput(kind: .image, path: "/private-fixture-not-read")
            if response == nil { XCTAssertEqual(try worker.embed(input, cancelled: { false }), semanticVector()) }
            else { XCTAssertThrowsError(try worker.embed(input, cancelled: { false })) }
            scope.cancel(); XCTAssertThrowsError(try worker.embed(input, cancelled: { false })); worker.release()
        }
    }
}
