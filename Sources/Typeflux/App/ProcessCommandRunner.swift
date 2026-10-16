import Darwin
import Foundation

struct ProcessCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ProcessCommandRunning {
    func run(executablePath: String, arguments: [String], environment: [String: String]?,
             currentDirectoryURL: URL?) async throws -> ProcessCommandResult
}

extension ProcessCommandRunning {
    func run(executablePath: String, arguments: [String]) async throws -> ProcessCommandResult {
        try await run(executablePath: executablePath, arguments: arguments, environment: nil, currentDirectoryURL: nil)
    }
}

enum ProcessCommandFailure: Error, LocalizedError {
    case timedOut, outputLimit

    var errorDescription: String? {
        switch self {
        case .timedOut: "The command timed out. An external action may already have taken effect; it was not replayed."
        case .outputLimit: "The command exceeded its output limit and was stopped."
        }
    }
}

final class ProcessCommandRunner: ProcessCommandRunning {
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let onProcessStarted: (@Sendable () -> Void)?

    /// Local model operations can be long-running. Interactive callers supply a
    /// smaller budget; all callers have a finite deadline and bounded output.
    init(timeout: TimeInterval = 900, outputLimit: Int = 16 * 1024 * 1024,
         onProcessStarted: (@Sendable () -> Void)? = nil) {
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.onProcessStarted = onProcessStarted
    }

    func run(executablePath: String, arguments: [String], environment: [String: String]? = nil,
             currentDirectoryURL: URL? = nil) async throws -> ProcessCommandResult {
        try Task.checkCancellation()
        let path = currentDirectoryURL?.path ?? FileManager.default.currentDirectoryPath
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        let environment = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { _, new in new }
        let result = try await ManagedProcess().run(.init(
            executable: executablePath, arguments: arguments, environment: environment,
            directoryDescriptor: directory, timeout: timeout, outputLimit: outputLimit,
            stopOnOutputLimit: true, preserveWhitespace: true, onStarted: onProcessStarted,
            immediateCleanupOnExit: true
        ))
        switch result.termination {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ProcessCommandFailure.timedOut
        case .outputLimit: throw ProcessCommandFailure.outputLimit
        default: break
        }
        guard !result.outputTruncated else { throw ProcessCommandFailure.outputLimit }
        guard result.exitCode == 0 else {
            throw NSError(domain: "ProcessCommandRunner", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: result.stderr.isEmpty ? result.stdout : result.stderr
            ])
        }
        return .init(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}
