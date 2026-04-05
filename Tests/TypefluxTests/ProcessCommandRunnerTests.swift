@testable import Typeflux
import XCTest

final class ProcessCommandRunnerTests: XCTestCase {
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
            currentDirectoryURL: nil,
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "test_value")
    }

    func testStderrIsCaptured() async {
        do {
            _ = try await runner.run(
                executablePath: "/usr/bin/env",
                arguments: ["bash", "-c", "echo error_output >&2; exit 1"],
            )
            XCTFail("Expected error")
        } catch let error as NSError {
            XCTAssertTrue(
                error.localizedDescription.contains("error_output"),
                "stderr should be captured in error description",
            )
        }
    }
}
