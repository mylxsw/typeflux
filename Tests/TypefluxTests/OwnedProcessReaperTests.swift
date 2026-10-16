import Darwin
import Foundation
@testable import Typeflux
import XCTest

final class OwnedProcessReaperTests: XCTestCase {
    private final class Child: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        func finish() {
            lock.withLock { done = true }
        }

        func reaped() -> Bool {
            lock.withLock { done }
        }
    }

    func testAdmissionRemainsBoundedUntilStuckChildActuallyExits() throws {
        let child = Child()
        let reaper = OwnedProcessReaper(capacity: 1, schedulesReaping: false) { _ in child.reaped() }
        try reaper.reserve()
        let notified = Child()
        reaper.collect(123) {
            // Callback must run outside the reaper lock and may reserve again.
            if (try? reaper.reserve()) != nil { reaper.release(); notified.finish() }
        }
        XCTAssertFalse(notified.reaped())
        XCTAssertThrowsError(try reaper.reserve())
        reaper.collectPending()
        XCTAssertThrowsError(try reaper.reserve())
        child.finish()
        reaper.collectPending()
        XCTAssertTrue(notified.reaped())
        try reaper.reserve()
        reaper.release()
    }

    func testLaunchFailureReturnsItsReservationAndExitedChildrenAreCollectedImmediately() throws {
        let reaper = OwnedProcessReaper(capacity: 1) { _ in true }
        try reaper.reserve()
        reaper.release()
        try reaper.reserve()
        reaper.collect(123)
        try reaper.reserve()
        reaper.release()
    }

    func testPendingChildrenAreReapedWithoutAnotherRequest() async throws {
        let child = Child()
        let reaper = OwnedProcessReaper(capacity: 2) { _ in child.reaped() }
        try reaper.reserve(); try reaper.reserve()
        reaper.collect(123); reaper.collect(124)
        XCTAssertThrowsError(try reaper.reserve())
        child.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if (try? reaper.reserve()) != nil {
                reaper.release(); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Reaper did not release admission after child exit")
    }
}
