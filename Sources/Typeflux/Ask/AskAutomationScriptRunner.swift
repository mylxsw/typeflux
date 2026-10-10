import Darwin
import Foundation

/// Only runs our short-lived AppleScript client. Killing it bounds local work;
/// it cannot undo an event already delivered to another application.
struct AskAutomationScriptRunner: ProcessCommandRunning {
    var timeout: TimeInterval = 22
    var outputLimit = 200_000
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?
    ) async throws -> ProcessCommandResult {
        guard executablePath == "/usr/bin/osascript", environment == nil, currentDirectoryURL == nil else {
            throw AskObservationError.invalid
        }
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw AskObservationError.invalid }
        defer { close(directory) }
        let result = try await ManagedProcess().run(.init(
            executable: executablePath, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            directoryDescriptor: directory, timeout: timeout, outputLimit: outputLimit
        ))
        switch result.termination {
        case .cancelled: throw CancellationError()
        case .timedOut: throw AskAutomationError.timeout
        default: break
        }
        guard result.exitCode == 0, !result.outputTruncated else { throw AskAutomationError.unavailable }
        return .init(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}

enum AskAutomationError: Error, LocalizedError {
    case timeout, unavailable
    var errorDescription: String? {
        switch self {
        case .timeout:
            "Browser automation timed out. A dispatched action may already have taken effect; do not replay it."
        case .unavailable:
            "Browser automation is unavailable. " +
                "Check Automation and browser JavaScript permissions, then observe again."
        }
    }
}
