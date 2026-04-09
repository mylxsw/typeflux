@testable import Typeflux
import XCTest

// MARK: - Unit tests for AliCloudFunASRDrainState
//
// These tests exercise the isolated drain-state actor that was extracted to make
// the "wait for last sentence or timeout" logic unit-testable without a real
// WebSocket connection. The actor mirrors the pattern used inside
// AliCloudFunASRSession: a continuation is stored when a drain is started, and
// `signal()` (called from handleEvent when sentence_end=true is received) resumes
// it early.

final class AliCloudFunASRDrainTests: XCTestCase {
    // MARK: - Fast path: no pending partial

    func testDrainReturnsImmediatelyWhenNoPendingPartial() async {
        let drain = AliCloudFunASRDrainState()
        let start = ContinuousClock.now

        // hasPartial=false → should return without suspending
        await drain.waitForSentenceEndOrTimeout(hasPartial: false, timeout: .seconds(5))

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(100), "drain must return immediately when no partial is pending")
    }

    // MARK: - Signal arrives before timeout

    func testDrainReturnsEarlyWhenSignalledBeforeTimeout() async {
        let drain = AliCloudFunASRDrainState()

        // Simulate: sentence_end=true arrives 100 ms after the drain starts.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await drain.signal()
        }

        let start = ContinuousClock.now
        await drain.waitForSentenceEndOrTimeout(hasPartial: true, timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThan(elapsed, .milliseconds(50), "drain must have waited for the signal")
        XCTAssertLessThan(elapsed, .seconds(1), "drain must NOT have waited for the full timeout")
    }

    // MARK: - Timeout fires when no signal arrives

    func testDrainTimesOutWhenNoSignalArrives() async {
        let drain = AliCloudFunASRDrainState()

        let start = ContinuousClock.now
        // timeout of 200 ms; no signal is sent
        await drain.waitForSentenceEndOrTimeout(hasPartial: true, timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThan(elapsed, .milliseconds(150), "drain must have waited for the timeout")
        XCTAssertLessThan(elapsed, .seconds(1), "drain must not overshoot the timeout by much")
    }

    // MARK: - Signal sent before wait begins (race-free via guard)

    func testDrainReturnsImmediatelyWhenSignalledBeforeWait() async {
        let drain = AliCloudFunASRDrainState()

        // Signal arrives before the wait is even entered: hasPartial=false simulates
        // the guard-check fast-path that fires when sentence_end=true already arrived.
        await drain.signal()

        let start = ContinuousClock.now
        await drain.waitForSentenceEndOrTimeout(hasPartial: false, timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    // MARK: - Multiple signals are idempotent

    func testSignalIsIdempotent() async {
        let drain = AliCloudFunASRDrainState()

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await drain.signal()
            await drain.signal() // second call must be a no-op
        }

        // Should return cleanly, no crash or hang
        await drain.waitForSentenceEndOrTimeout(hasPartial: true, timeout: .seconds(5))
    }

    // MARK: - Error path: signal via signalOnError exits drain early

    func testSignalOnErrorExitsDrainImmediately() async {
        let drain = AliCloudFunASRDrainState()

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await drain.signal() // mirrors signalError calling resumeLastSentenceCont()
        }

        let start = ContinuousClock.now
        await drain.waitForSentenceEndOrTimeout(hasPartial: true, timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
