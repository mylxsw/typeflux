@testable import Typeflux
import XCTest

final class ModuleRecoveryBudgetTests: XCTestCase {
    func testRepeatedFailuresBackOffAndOpenCircuitWithOneProbeAfterCooldown() {
        var budget = ModuleRecoveryBudget()
        XCTAssertTrue(budget.permitsAttempt(at: 0))
        budget.failed(at: 0)
        XCTAssertEqual(budget.state, .waiting(until: 1))
        XCTAssertFalse(budget.permitsAttempt(at: 0.9))
        budget.failed(at: 1)
        XCTAssertEqual(budget.state, .waiting(until: 3))
        budget.failed(at: 3)
        XCTAssertEqual(budget.state, .waiting(until: 7))
        budget.failed(at: 7)
        XCTAssertEqual(budget.state, .circuitOpen(until: 307))
        XCTAssertFalse(budget.permitsAttempt(at: 306))
        XCTAssertTrue(budget.permitsAttempt(at: 307))
        budget.failed(at: 307)
        XCTAssertEqual(budget.state, .circuitOpen(until: 607))
        budget.succeeded(at: 607)
        XCTAssertEqual(budget.state, .available)
    }

    func testOldFailuresExpireAndStableSuccessDoesNotAccumulateRestarts() {
        var budget = ModuleRecoveryBudget()
        budget.failed(at: 0)
        budget.failed(at: 61)
        XCTAssertEqual(budget.state, .waiting(until: 62))
        budget.succeeded(at: 62)
        budget.succeeded(at: 663)
        budget.failed(at: 664)
        XCTAssertEqual(budget.state, .waiting(until: 665))
    }
}
