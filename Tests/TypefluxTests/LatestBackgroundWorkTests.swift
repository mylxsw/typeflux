import Foundation
import XCTest
@testable import Typeflux

final class LatestBackgroundWorkTests: XCTestCase {
    func testTimeoutDoesNotReleaseOccupiedSlotAndOnlyNewestRequestRuns() async {
        let worker = LatestBackgroundWork(label: "test.bounded-background", timeout: 0.2)
        let started = expectation(description: "blocked worker started")
        let expired = expectation(description: "caller released")
        let superseded = expectation(description: "middle request cancelled")
        let finished = expectation(description: "newest request finished")
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var didRunLast = false
        worker.submit({
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }, completion: { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case let .failure(error) = result, error as? BackgroundWorkFailure == .timedOut else {
                return XCTFail("Expected a timeout")
            }
            expired.fulfill()
        })
        await fulfillment(of: [started, expired], timeout: 2)
        worker.submit({ XCTFail("Superseded work must never run") }, completion: { result in
            if case .failure = result { superseded.fulfill() }
        })
        worker.submit({ lock.withLock { didRunLast = true } }, completion: { result in
            if case .failure = result { XCTFail("Newest request should complete") }
            finished.fulfill()
        })
        XCTAssertFalse(lock.withLock { didRunLast })
        gate.signal()
        await fulfillment(of: [superseded, finished], timeout: 2)
        XCTAssertTrue(lock.withLock { didRunLast })
    }

    func testCancelReturnsOnceAndWorkerCanBeReusedAfterItDrains() async {
        let worker = LatestBackgroundWork(label: "test.cancel-background")
        let started = expectation(description: "started")
        let cancelled = expectation(description: "cancelled")
        let done = expectation(description: "replacement")
        let gate = DispatchSemaphore(value: 0)
        worker.submit({ started.fulfill(); _ = gate.wait(timeout: .now() + 3) }, completion: { result in
            guard case let .failure(error) = result, error as? BackgroundWorkFailure == .cancelled else {
                return XCTFail("Expected cancellation, never late success")
            }
            cancelled.fulfill()
        })
        await fulfillment(of: [started], timeout: 1)
        worker.cancel(); worker.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        worker.submit({}, completion: { _ in done.fulfill() })
        gate.signal()
        await fulfillment(of: [done], timeout: 2)
    }
}
