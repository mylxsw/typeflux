import Darwin
import Foundation
import XCTest
@testable import Typeflux

final class SemanticReaderOwnershipTests: XCTestCase {
    private let request = AskFileReadRequest(operation: .resolve, path: "/private-synthetic")

    func testScopesReuseOneReaderWithoutReplayingAndOldStopCannotStopNewScope() throws {
        let fixture = SemanticLaneFixture(), lane = SemanticFileReaderLane(makeReader: { fixture.make() })
        var old: SemanticScopedFileReader? = lane.scope()
        XCTAssertEqual(fixture.created, 0)
        XCTAssertEqual(try old?.read(request, isCancelled: { false }).path, request.path)
        let next = lane.scope()
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertThrowsError(try old?.read(request, isCancelled: { false }))
        XCTAssertEqual(try next.read(request, isCancelled: { false }).path, request.path)
        let stops = fixture.stops
        old = nil
        XCTAssertEqual(fixture.stops, stops)
        XCTAssertEqual(fixture.created, 1)
        next.stop()
        XCTAssertThrowsError(try next.read(request, isCancelled: { false }))
    }

    func testBlockedFactoryHoldsAdmissionAcrossManyReplacementsAndDoesNotQueue() throws {
        let fixture = SemanticLaneFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lane = SemanticFileReaderLane(makeReader: {
            entered.signal(); release.wait(); return fixture.make()
        })
        let old = lane.scope(), group = DispatchGroup(), request = request
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { _ = try old.read(request, isCancelled: { false }); XCTFail("Revoked factory returned success") }
            catch {}
        }
        defer { release.signal(); XCTAssertEqual(group.wait(timeout: .now() + 3), .success) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        for _ in 0..<25 {
            let next = lane.scope()
            XCTAssertThrowsError(try next.read(request, isCancelled: { false }))
        }
        XCTAssertEqual(fixture.created, 0)
    }

    func testUncooperativeConsumerRetainsLaneAndRejectsLateSuccess() throws {
        let fixture = SemanticLaneFixture(), lanes = SemanticFileReaders(makeReader: { fixture.make() })
        let old = lanes.validation.scope(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), request = request
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try old.stream(request, isCancelled: { false }) { _ in
                    entered.signal(); release.wait(); return true
                }
                XCTFail("Revoked callback returned success")
            } catch {}
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        lanes.stop()
        let next = lanes.validation.scope()
        XCTAssertThrowsError(try next.read(request, isCancelled: { false }))
        let index = lanes.indexing.scope(), priority = lanes.priority.scope()
        XCTAssertNoThrow(try index.read(request, isCancelled: { false }))
        XCTAssertNoThrow(try priority.read(request, isCancelled: { false }))
        XCTAssertEqual(fixture.created, 3, "Only independent lanes may allocate readers")
        release.signal(); XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        // Host completion alone does not finish the coalesced serial cleanup.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while lanes.validation.isOccupied, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(lanes.validation.isOccupied)
        let calls = fixture.calls
        XCTAssertEqual(calls, 3, "Retirement never queues a replacement operation")
        XCTAssertNoThrow(try next.read(request, isCancelled: { false }))
        XCTAssertEqual(fixture.created, 3)
        lanes.stop()
    }

    func testStopAndCancellationSuppressCallbacksEvenIfInjectedReaderIgnoresCancellation() throws {
        let fixture = SemanticLaneFixture(), lane = SemanticFileReaderLane(makeReader: { fixture.make() })
        let reader = lane.scope(), cancellation = AskSearchCancellation()
        XCTAssertThrowsError(try reader.read(request, isCancelled: { true }))
        XCTAssertEqual(fixture.created, 0)
        fixture.beforeResponse = { cancellation.cancel() }
        var callbacks = 0
        XCTAssertThrowsError(try reader.stream(request, isCancelled: { cancellation.isCancelled }) { _ in
            callbacks += 1; return true
        })
        XCTAssertEqual(callbacks, 0)
        fixture.beforeResponse = nil
        XCTAssertNoThrow(try reader.stream(request, isCancelled: { false }) { _ in false })
        fixture.failure = true
        XCTAssertThrowsError(try reader.read(request, isCancelled: { false }))
        fixture.failure = false
        XCTAssertNoThrow(try reader.read(request, isCancelled: { false }))
        reader.stop()
    }

    func testOwnerReleaseRevokesRetainedScopeWithoutStartingFactory() throws {
        let fixture = SemanticLaneFixture()
        var owners: SemanticFileReaders? = SemanticFileReaders(makeReader: { fixture.make() })
        let retained = try XCTUnwrap(owners?.validation.scope())
        owners = nil
        XCTAssertThrowsError(try retained.read(request, isCancelled: { false }))
        XCTAssertEqual(fixture.created, 0)
    }

    func testNativeChildCollectionStillBlocksSameLaneAfterHostReturns() throws {
        let owner = AskFileReaderOwnership(), collect = AskSearchCancellation()
        let reaper = OwnedProcessReaper(schedulesReaping: false, reaped: { pid in
            guard collect.isCancelled else { return false }
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == pid
        })
        let lane = SemanticFileReaderLane(makeReader: {
            AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                "while IFS= read -r line; do printf '{\"entries\":[],\"path\":\"/synthetic\"}\\n'; done"],
                ownership: owner, reaper: reaper)
        })
        defer {
            lane.stop(); collect.cancel()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while owner.isOccupied, ProcessInfo.processInfo.systemUptime < deadline {
                reaper.collectPending(); Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(owner.isOccupied)
        }
        let old = lane.scope()
        XCTAssertEqual(try old.read(request, isCancelled: { false }).path, "/synthetic")
        let next = lane.scope()
        XCTAssertTrue(owner.isOccupied)
        XCTAssertThrowsError(try next.read(request, isCancelled: { false }))
        collect.cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while owner.isOccupied, ProcessInfo.processInfo.systemUptime < deadline {
            reaper.collectPending(); Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(owner.isOccupied)
        XCTAssertEqual(try next.read(request, isCancelled: { false }).path, "/synthetic")
        XCTAssertThrowsError(try old.read(request, isCancelled: { false }))
    }

    func testDefaultNativeLanesOnlyResolvePrivateFixtureAndRevokeOldScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = SemanticFileReaders(), first = lanes.validation.scope()
        XCTAssertEqual(URL(fileURLWithPath: try first.resolve(root.path, blocked: [])).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        let next = lanes.validation.scope()
        XCTAssertThrowsError(try first.resolve(root.path, blocked: []))
        XCTAssertNoThrow(try next.resolve(root.path, blocked: []))
        lanes.stop()
    }

    func testValidatorReportsOccupiedOrRevokedScopeAsIncomplete() throws {
        let fixture = SemanticLaneFixture(), lane = SemanticFileReaderLane(makeReader: { fixture.make() })
        let old = lane.scope(), validator = SemanticFileValidator(reader: old)
        let next = lane.scope()
        let hit = AskFileHit(path: "/synthetic/note.txt", name: "note", kind: .file, modified: Date(), score: 1)
        let scope = semanticScope("/synthetic")
        let result = validator.validateBatch([hit], scope: scope, limit: 1, cancelled: { false })
        XCTAssertFalse(result.complete); XCTAssertTrue(result.hits.isEmpty)
        let busy = SemanticFileValidator(reader: SemanticUnavailableReader())
        XCTAssertFalse(busy.validateBatch([hit], scope: scope, limit: 1, cancelled: { false }).complete)
        next.stop()
    }

    func testQuietStopCoalescesOffCallerAndKeepsAdmissionWhileCleanupBlocks() throws {
        let fixture = SemanticLaneFixture(), lane = SemanticFileReaderLane(makeReader: { fixture.make() })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), once = AskSearchCancellation()
        fixture.beforeStop = {
            if !once.isCancelled {
                once.cancel(); entered.signal(); release.wait(); done.signal()
            }
        }
        let first = lane.scope()
        XCTAssertNoThrow(try first.read(request, isCancelled: { false }))
        let start = ProcessInfo.processInfo.systemUptime
        lane.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        for _ in 0..<20 { lane.stop() }
        let next = lane.scope()
        XCTAssertThrowsError(try next.read(request, isCancelled: { false }))
        XCTAssertEqual(fixture.created, 1)
        release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        next.stop()
    }
}

private final class SemanticUnavailableReader: AskFileReading {
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        throw AskFileReadError.unavailable
    }
}

private final class SemanticLaneFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var allocations = 0, reads = 0, stopped = 0
    var beforeResponse: (() -> Void)?
    var beforeStop: (() -> Void)?
    var failure = false
    var created: Int { lock.withLock { allocations } }
    var calls: Int { lock.withLock { reads } }
    var stops: Int { lock.withLock { stopped } }
    func make() -> any AskFileReading { lock.withLock { allocations += 1 }; return Reader(fixture: self) }
    private final class Reader: AskFileReading {
        let fixture: SemanticLaneFixture
        init(fixture: SemanticLaneFixture) { self.fixture = fixture }
        func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
            fixture.lock.withLock { fixture.reads += 1 }
            fixture.beforeResponse?()
            if fixture.failure { throw AskFileReadError.protocolError }
            return .init(path: request.path)
        }
        func stop() { fixture.beforeStop?(); fixture.lock.withLock { fixture.stopped += 1 } }
    }
}
