@testable import Typeflux
import XCTest

@MainActor
final class TerminationPreparationLatchTests: XCTestCase {
    func testSuccessfulPreparationRunsOnlyOnce() async {
        let latch = TerminationPreparationLatch()
        var runs = 0
        let first = await latch.run { runs += 1; return true }
        let second = await latch.run { runs += 1; return false }
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(latch.hasSucceeded)
    }

    func testRefusedPreparationCanBeRetried() async {
        let latch = TerminationPreparationLatch()
        var runs = 0
        let refused = await latch.run { runs += 1; return false }
        XCTAssertFalse(refused)
        XCTAssertFalse(latch.hasSucceeded)
        let retried = await latch.run { runs += 1; return true }
        XCTAssertTrue(retried)
        XCTAssertEqual(runs, 2)
    }

    func testConcurrentCallersShareOneAttempt() async {
        let latch = TerminationPreparationLatch()
        var runs = 0
        async let first = latch.run {
            runs += 1
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        async let second = latch.run { runs += 1; return true }
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(runs, 1)
    }
}
