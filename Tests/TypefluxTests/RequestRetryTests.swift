import XCTest
@testable import Typeflux

final class RequestRetryTests: XCTestCase {
    private actor Recorder {
        var attemptCount = 0
        var retryNumbers: [Int] = []
        var retryDelays: [Duration] = []
        var sleptDurations: [Duration] = []

        func incrementAttempt() -> Int {
            attemptCount += 1
            return attemptCount
        }

        func recordRetry(number: Int, delay: Duration) {
            retryNumbers.append(number)
            retryDelays.append(delay)
        }

        func recordSleep(_ duration: Duration) {
            sleptDurations.append(duration)
        }
    }

    func testRetriesUseConfiguredDelaySequence() async throws {
        let expectedDelays: [Duration] = [.zero, .milliseconds(500), .seconds(2)]
        let expectedError = NSError(domain: "RequestRetryTests", code: 42, userInfo: nil)
        let recorder = Recorder()

        do {
            _ = try await RequestRetry.perform(
                operationName: "test-operation",
                onRetry: { retryNumber, _, delay in
                    await recorder.recordRetry(number: retryNumber, delay: delay)
                },
                sleep: { duration in
                    await recorder.recordSleep(duration)
                },
                operation: {
                    _ = await recorder.incrementAttempt()
                    throw expectedError
                }
            ) as String
            XCTFail("Expected retry helper to rethrow the final error")
        } catch {
            XCTAssertEqual((error as NSError).domain, expectedError.domain)
            XCTAssertEqual((error as NSError).code, expectedError.code)
        }

        let attempts = await recorder.attemptCount
        let retryNumbers = await recorder.retryNumbers
        let retryDelays = await recorder.retryDelays
        let sleptDurations = await recorder.sleptDurations

        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(retryNumbers, [1, 2, 3])
        XCTAssertEqual(retryDelays, expectedDelays)
        XCTAssertEqual(sleptDurations, expectedDelays)
    }

    func testStopsRetryingAfterSuccessfulAttempt() async throws {
        let recorder = Recorder()

        let result = try await RequestRetry.perform(
            operationName: "test-operation",
            sleep: { duration in
                await recorder.recordSleep(duration)
            },
            operation: {
                let attemptCount = await recorder.incrementAttempt()
                if attemptCount < 3 {
                    throw NSError(domain: "RequestRetryTests", code: attemptCount, userInfo: nil)
                }
                return "ok"
            }
        )

        let attempts = await recorder.attemptCount
        let sleptDurations = await recorder.sleptDurations

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleptDurations, [.zero, .milliseconds(500)])
    }

    func testDoesNotRetryCancellationError() async {
        let recorder = Recorder()

        do {
            _ = try await RequestRetry.perform(
                operationName: "test-operation",
                onRetry: { retryNumber, _, delay in
                    await recorder.recordRetry(number: retryNumber, delay: delay)
                },
                sleep: { duration in
                    await recorder.recordSleep(duration)
                },
                operation: {
                    _ = await recorder.incrementAttempt()
                    throw CancellationError()
                }
            ) as String
            XCTFail("Expected cancellation to be rethrown")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let attempts = await recorder.attemptCount
        let retryNumbers = await recorder.retryNumbers
        let sleptDurations = await recorder.sleptDurations

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(retryNumbers.isEmpty)
        XCTAssertTrue(sleptDurations.isEmpty)
    }
}
