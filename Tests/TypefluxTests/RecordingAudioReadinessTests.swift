import XCTest

@testable import Typeflux

final class RecordingAudioReadinessTests: XCTestCase {
    func testAudioBeforeSetupIsRememberedAndDeliveredOnce() {
        let readiness = RecordingAudioReadiness()
        readiness.receiveAudio()
        var calls = 0
        readiness.whenReady { calls += 1 }
        readiness.receiveAudio()
        readiness.whenReady { calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testSetupWaitsForAudioAndCallbackCanReenter() {
        let readiness = RecordingAudioReadiness()
        var calls = 0
        readiness.whenReady {
            calls += 1
            XCTAssertTrue(readiness.isReady)
            readiness.cancel()
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(readiness.isReady)
        readiness.receiveAudio()
        readiness.receiveAudio()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(readiness.isReady)
    }

    func testCancellationDiscardsPendingAndFutureCallbacks() {
        let readiness = RecordingAudioReadiness()
        readiness.whenReady { XCTFail("Cancelled recording must not become ready") }
        readiness.cancel()
        readiness.receiveAudio()
        readiness.whenReady { XCTFail("Late setup must not revive a cancelled recording") }
        XCTAssertFalse(readiness.isReady)
    }

    func testConcurrentAudioAndSetupDeliverOnce() {
        let readiness = RecordingAudioReadiness()
        let lock = NSLock()
        var calls = 0
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) {
                readiness.receiveAudio()
            } else {
                readiness.whenReady { lock.withLock { calls += 1 } }
            }
        }
        XCTAssertEqual(calls, 1)
    }
}
