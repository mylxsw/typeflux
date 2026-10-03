import Testing
@testable import Typeflux

@Suite("Managed AppleScript client")
struct AskAutomationScriptRunnerTests {
    @Test func `real short lived script and rejected inputs`() async throws {
        let runner = AskAutomationScriptRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "return \"controlled\""]
        )
        #expect(result.stdout == "controlled"); #expect(result.exitCode == 0)
        await #expect(throws: AskObservationError.invalid) {
            try await runner.run(executablePath: "/bin/sh", arguments: [], environment: nil, currentDirectoryURL: nil)
        }
        await #expect(throws: AskObservationError.invalid) {
            try await runner.run(
                executablePath: "/usr/bin/osascript",
                arguments: [],
                environment: ["UNTRUSTED": "1"],
                currentDirectoryURL: nil
            )
        }
        await #expect(throws: AskAutomationError.self) {
            try await runner.run(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", "error \"controlled failure\""]
            )
        }
    }

    @Test func `cancellation of real client is bounded`() async throws {
        let task = Task { try await AskAutomationScriptRunner().run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "delay 30\nreturn \"late\""]
        ) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(2))
    }
}
