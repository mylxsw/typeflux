@testable import Typeflux
import XCTest

final class ProcessCommandRunnerTests: XCTestCase {
    func testIgnoringTerminationCannotHoldCommandOpen() async throws {
        let runner = ProcessCommandRunner(timeout: 0.1)
        let started = ContinuousClock.now
        do {
            _ = try await runner.run(executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"])
            XCTFail("Expected deadline")
        } catch ProcessCommandFailure.timedOut {}
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testFloodStopsAtOutputBudgetAndRunnerCanBeUsedAgain() async throws {
        let runner = ProcessCommandRunner(timeout: 5, outputLimit: 100)
        do {
            _ = try await runner.run(executablePath: "/usr/bin/yes", arguments: [])
            XCTFail("Expected output limit")
        } catch ProcessCommandFailure.outputLimit {}
        let result = try await runner.run(executablePath: "/bin/echo", arguments: ["recovered"])
        XCTAssertEqual(result.stdout, "recovered\n")
    }

    func testWorkerCrashDoesNotPreventNextCommand() async throws {
        do {
            _ = try await runner.run(executablePath: "/bin/sh", arguments: ["-c", "kill -KILL $$"])
            XCTFail("Expected signal failure")
        } catch let error as NSError { XCTAssertEqual(error.code, 137) }
        let result = try await runner.run(executablePath: "/bin/echo", arguments: ["alive"])
        XCTAssertEqual(result.stdout, "alive\n")
    }

    func testPipeHoldingDescendantCannotBlockCompletion() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run(executablePath: "/bin/sh", arguments: ["-c", "sleep 30 & echo done"])
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testWorkingDirectoryLaunchFailureAndInvalidBudgets() async throws {
        let result = try await runner.run(executablePath: "/bin/pwd", arguments: [], environment: nil,
                                          currentDirectoryURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(result.stdout, "/\n")
        do {
            _ = try await runner.run(executablePath: "/bin/pwd", arguments: [], environment: nil,
                                     currentDirectoryURL: URL(fileURLWithPath: "/nonexistent-typeflux-directory"))
            XCTFail("Expected invalid directory")
        } catch {}
        do { _ = try await runner.run(executablePath: "/nonexistent-typeflux", arguments: []); XCTFail() } catch {}
        do {
            _ = try await ProcessCommandRunner(timeout: .nan)
                .run(executablePath: "/bin/echo", arguments: []); XCTFail()
        } catch {}
        XCTAssertNotNil(ProcessCommandFailure.timedOut.errorDescription)
        XCTAssertNotNil(ProcessCommandFailure.outputLimit.errorDescription)
    }

    func testAlreadyCancelledCommandDoesNotLaunch() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(executablePath: "/bin/echo", arguments: [])
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
    }

    private var runner: ProcessCommandRunner!

    override func setUp() {
        super.setUp()
        runner = ProcessCommandRunner()
    }

    override func tearDown() {
        runner = nil
        super.tearDown()
    }

    func testEchoCommandReturnsExpectedStdout() async throws {
        let result = try await runner.run(executablePath: "/bin/echo", arguments: ["hello world"])
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExitCodeIsCapturedCorrectly() async throws {
        let result = try await runner.run(executablePath: "/bin/echo", arguments: ["-n", "ok"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testFailedCommandThrowsWithNonZeroExitCode() async {
        do {
            _ = try await runner.run(executablePath: "/usr/bin/env", arguments: ["false"])
            XCTFail("Expected error for non-zero exit code")
        } catch let error as NSError {
            XCTAssertNotEqual(error.code, 0)
        }
    }

    func testEnvironmentVariablesAreMerged() async throws {
        let result = try await runner.run(
            executablePath: "/usr/bin/env",
            arguments: ["bash", "-c", "echo $TYPEFLUX_TEST_VAR"],
            environment: ["TYPEFLUX_TEST_VAR": "test_value"],
            currentDirectoryURL: nil
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "test_value")
    }

    func testStderrIsCaptured() async {
        do {
            _ = try await runner.run(
                executablePath: "/usr/bin/env",
                arguments: ["bash", "-c", "echo error_output >&2; exit 1"]
            )
            XCTFail("Expected error")
        } catch let error as NSError {
            XCTAssertTrue(
                error.localizedDescription.contains("error_output"),
                "stderr should be captured in error description"
            )
        }
    }

    func testCancellationTerminatesRunningProcess() async {
        let started = expectation(description: "process started")
        let completed = expectation(description: "cancelled process completed")
        let runner = ProcessCommandRunner {
            started.fulfill()
        }
        let task = Task {
            defer { completed.fulfill() }
            do {
                _ = try await runner.run(executablePath: "/bin/sleep", arguments: ["60"])
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
    }
}
