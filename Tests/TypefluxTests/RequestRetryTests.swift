@testable import Typeflux
import XCTest

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

    func testUncertainPaidCloudFailureStopsNestedRetryLoops() async {
        let recorder = Recorder()
        let original = URLError(.networkConnectionLost)
        do {
            _ = try await RequestRetry.perform(operationName: "outer", sleep: { _ in }) {
                try await RequestRetry.perform(operationName: "inner", sleep: { _ in }) {
                    _ = await recorder.incrementAttempt()
                    throw RequestRetry.protectingPaidCloudFailure(original)
                } as String
            }
            XCTFail("Expected the paid invocation to stop")
        } catch {
            let wrapped = error as NSError
            XCTAssertEqual(wrapped.localizedDescription, original.localizedDescription)
            XCTAssertEqual(wrapped.domain, NSURLErrorDomain)
            XCTAssertEqual(wrapped.code, URLError.networkConnectionLost.rawValue)
            XCTAssertEqual(wrapped.userInfo[RequestRetry.paidCloudNoReplayKey] as? Bool, true)
            XCTAssertNotNil(wrapped.userInfo[NSUnderlyingErrorKey])
        }
        let attempts = await recorder.attemptCount
        XCTAssertEqual(attempts, 1)
    }

    func testConfirmedUnadmittedCloudRequestMayRetry() async throws {
        let recorder = Recorder()
        let body = Data(#"{"code":"BILLING_SYNC_PENDING","message":"synchronizing"}"#.utf8)
        let pending = NSError(domain: "LLM", code: 503, userInfo: [RequestRetry.responseBodyKey: body])
        let result = try await RequestRetry.perform(operationName: "cold credits", sleep: { _ in }) {
            let attempt = await recorder.incrementAttempt()
            if attempt == 1 { throw RequestRetry.protectingPaidCloudFailure(pending) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        let attempts = await recorder.attemptCount
        XCTAssertEqual(attempts, 2)
    }

    func testGeneric503DoesNotProvePaidWorkWasNeverAdmitted() {
        let body = Data(#"{"code":"UPSTREAM_ERROR","message":"BILLING_SYNC_PENDING"}"#.utf8)
        let failure = NSError(domain: "LLM", code: 503, userInfo: [RequestRetry.responseBodyKey: body])
        let protected = RequestRetry.protectingPaidCloudFailure(failure) as NSError
        XCTAssertEqual(protected.userInfo[RequestRetry.paidCloudNoReplayKey] as? Bool, true)
        let malformed = NSError(domain: "LLM", code: 503, userInfo: [RequestRetry.responseBodyKey: Data("bad".utf8)])
        XCTAssertEqual((RequestRetry.protectingPaidCloudFailure(malformed) as NSError).userInfo[RequestRetry.paidCloudNoReplayKey] as? Bool, true)
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

    func testRetryPredicateCanStopRetryingRecoverableOperation() async {
        let recorder = Recorder()
        let expectedError = NSError(domain: "RequestRetryTests", code: 503)

        do {
            _ = try await RequestRetry.perform(
                operationName: "test-operation",
                shouldRetry: { _ in false },
                sleep: { duration in
                    await recorder.recordSleep(duration)
                },
                operation: {
                    _ = await recorder.incrementAttempt()
                    throw expectedError
                }
            ) as String
            XCTFail("Expected retry predicate to rethrow immediately")
        } catch {
            XCTAssertEqual((error as NSError).code, 503)
        }

        let attemptCount = await recorder.attemptCount
        let sleptDurations = await recorder.sleptDurations
        XCTAssertEqual(attemptCount, 1)
        XCTAssertTrue(sleptDurations.isEmpty)
    }

    func testDoesNotRetryTypefluxCloudBillingError() async {
        let recorder = Recorder()
        let expectedError = TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nil)

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
            XCTFail("Expected billing error to be rethrown")
        } catch let error as TypefluxCloudBillingError {
            XCTAssertEqual(error.reason, .subscriptionRequired)
        } catch {
            XCTFail("Expected TypefluxCloudBillingError, got \(error)")
        }

        let attempts = await recorder.attemptCount
        let retryNumbers = await recorder.retryNumbers
        let sleptDurations = await recorder.sleptDurations

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(retryNumbers.isEmpty)
        XCTAssertTrue(sleptDurations.isEmpty)
    }

    func testDoesNotRetryTypefluxCloudLoginRequiredError() async {
        let recorder = Recorder()
        let expectedError = TypefluxCloudLoginRequiredError()

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
            XCTFail("Expected login required error to be rethrown")
        } catch let error as TypefluxCloudLoginRequiredError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Expected TypefluxCloudLoginRequiredError, got \(error)")
        }

        let attempts = await recorder.attemptCount
        let retryNumbers = await recorder.retryNumbers
        let sleptDurations = await recorder.sleptDurations

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(retryNumbers.isEmpty)
        XCTAssertTrue(sleptDurations.isEmpty)
    }
}

// MARK: - Extended RequestRetry tests

extension RequestRetryTests {
    func testRetryDelaysCountIsCorrect() {
        // The default delays are [.zero, .milliseconds(500), .seconds(2)]
        XCTAssertEqual(RequestRetry.retryDelays.count, 3)
    }

    func testFirstRetryDelayIsZero() {
        let first = RequestRetry.retryDelays[0]
        XCTAssertEqual(first, .zero)
    }

    func testSecondRetryDelayIsHalfSecond() {
        let second = RequestRetry.retryDelays[1]
        XCTAssertEqual(second, .milliseconds(500))
    }

    func testThirdRetryDelayIsTwoSeconds() {
        let third = RequestRetry.retryDelays[2]
        XCTAssertEqual(third, .seconds(2))
    }

    func testSucceedsImmediatelyWithoutRetry() async throws {
        let recorder = Recorder()
        let result = try await RequestRetry.perform(
            operationName: "immediate-success",
            sleep: { _ in }
        ) {
            _ = await recorder.incrementAttempt()
            return "success"
        }
        XCTAssertEqual(result, "success")
        let callCount = await recorder.attemptCount
        XCTAssertEqual(callCount, 1)
    }

    func testThrowsAfterExhaustingRetries() async {
        let recorder = Recorder()
        do {
            _ = try await RequestRetry.perform(
                operationName: "always-fails",
                sleep: { _ in }
            ) {
                let count = await recorder.incrementAttempt()
                throw NSError(domain: "test", code: count)
            } as String
            XCTFail("Expected error to be thrown")
        } catch {
            let nsErr = error as NSError
            let callCount = await recorder.attemptCount
            // Should have been retried 3 times total (1 original + 3 retries count exceeded)
            XCTAssertEqual(callCount, 4) // 1 original + 3 retry attempts
            XCTAssertEqual(nsErr.domain, "test")
        }
    }
}
