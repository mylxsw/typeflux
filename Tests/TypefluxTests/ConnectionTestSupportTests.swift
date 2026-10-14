@testable import Typeflux
import XCTest

final class ConnectionTestSupportTests: XCTestCase {
    private actor Recorder {
        var durations: [Duration] = []
        var operationCancelled = false

        func record(_ duration: Duration) { durations.append(duration) }
        func recordCancellation() { operationCancelled = true }
    }

    private enum Failure: Error { case expected }

    func testRunWithTimeoutReturnsOperationResultBeforeDeadline() async throws {
        let result = try await ConnectionTestSupport.runWithTimeout {
            "ok"
        }

        XCTAssertEqual(result, "ok")
    }

    func testRunWithTimeoutThrowsTimeoutErrorAfterDeadline() async {
        let recorder = Recorder()
        do {
            _ = try await ConnectionTestSupport.runWithTimeout(sleep: { duration in
                await recorder.record(duration)
            }, {
                do {
                    try await Task.sleep(for: .seconds(ConnectionTestSupport.timeoutSeconds + 1))
                } catch {
                    await recorder.recordCancellation()
                    throw error
                }
                return "late"
            })
            XCTFail("Expected timeout to be thrown")
        } catch let error as ConnectionTestError {
            XCTAssertEqual(error, .timedOut(seconds: 30))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let durations = await recorder.durations
        let cancelled = await recorder.operationCancelled
        XCTAssertEqual(durations, [.seconds(30)])
        XCTAssertTrue(cancelled, "The timeout must cancel and join the operation")
    }

    func testRunWithTimeoutPropagatesOperationError() async {
        do {
            _ = try await ConnectionTestSupport.runWithTimeout {
                throw Failure.expected
            } as String
            XCTFail("Expected operation failure")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    func testRunWithTimeoutPropagatesSleepErrorAndCancelsOperation() async {
        let recorder = Recorder()
        do {
            _ = try await ConnectionTestSupport.runWithTimeout(sleep: { _ in throw Failure.expected }, {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await recorder.recordCancellation()
                    throw error
                }
                return "late"
            })
            XCTFail("Expected sleep failure")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        let cancelled = await recorder.operationCancelled
        XCTAssertTrue(cancelled)
    }

    func testRunWithTimeoutPropagatesCallerCancellation() async {
        let task = Task {
            try await ConnectionTestSupport.runWithTimeout {
                try await Task.sleep(for: .seconds(60))
                return "late"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
