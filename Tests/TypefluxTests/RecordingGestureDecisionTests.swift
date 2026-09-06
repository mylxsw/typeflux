import XCTest
@testable import Typeflux

final class RecordingGestureDecisionTests: XCTestCase {
    func testTimerSettlesSingleTapWithoutAnotherEvent() async {
        let decision = RecordingGestureDecision()
        let settled = expectation(description: "Single tap settled")
        Task {
            await decision.wait()
            settled.fulfill()
        }
        decision.schedule(after: 0)
        await fulfillment(of: [settled], timeout: 2)
    }

    func testAskSelectionResolvesBeforeStartupBeginsWaiting() async {
        let decision = RecordingGestureDecision()
        decision.schedule(after: 60)
        decision.resolve()
        decision.resolve()
        decision.schedule(after: 60)
        let settled = expectation(description: "Ask selection preserved")
        Task {
            await decision.wait()
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 2)
    }

    @MainActor
    func testReleaseReplacesHoldDeadline() async {
        let decision = RecordingGestureDecision()
        decision.schedule(after: 0)
        decision.schedule(after: 60)
        let premature = expectation(description: "Old deadline must not settle gesture")
        premature.isInverted = true
        let waiter = Task {
            await decision.wait()
            if !Task.isCancelled { premature.fulfill() }
        }
        await fulfillment(of: [premature], timeout: 0.05)
        waiter.cancel()
        decision.resolve()
        await waiter.value
    }
}
