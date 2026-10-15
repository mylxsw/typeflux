import Darwin
import Foundation

/// One process to start for a workflow run.
struct AskWorkflowInvocation: Sendable {
    var launch: AskWorkflowRuntime.Launch
    var environment: [String: String]
    var directory: URL
    var stdin: Data
    var timeout: Double
    var stdoutLimit = 1_000_000
    var stderrLimit = 256_000
}

/// How a run ended.
struct AskWorkflowRunResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: Double
    var timedOut = false
    /// The output passed its limit and the run was stopped.
    var truncated = false
}

enum AskWorkflowRunEvent: Equatable, Sendable {
    /// Everything printed so far, up to the last complete line.
    case output(String)
    case finished(AskWorkflowRunResult)
}

enum AskWorkflowRunError: Error, Equatable {
    /// The process could not start; carries `errno`.
    case spawnFailed(Int32)
}

/// Runs workflow processes. Each run gets its own process group, so a timeout or
/// a cancel ends children that remain in that group; its environment is exactly the
/// one given, never Typeflux's own; and its output is capped.
protocol AskWorkflowRunning: Sendable {
    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error>
}

final class AskWorkflowRunner: AskWorkflowRunning, @unchecked Sendable {
    var killGrace: Double = 1
    var drainGrace: Double = 0.3

    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error> {
        let killGrace = killGrace, drainGrace = drainGrace
        // Cumulative progress can be coalesced. Keep the latest progress and the
        // final result even when the UI consumes events more slowly than the child.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                let started = ContinuousClock.now
                do {
                    try Task.checkCancellation()
                    let directory = open(invocation.directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    guard directory >= 0 else { throw AskWorkflowRunError.spawnFailed(errno) }
                    defer { close(directory) }
                    let result = try await ManagedProcess().run(.init(
                        executable: invocation.launch.executable.path, arguments: invocation.launch.arguments,
                        environment: invocation.environment, directoryDescriptor: directory,
                        timeout: invocation.timeout, outputLimit: invocation.stdoutLimit,
                        stopOnOutputLimit: true, preserveWhitespace: true,
                        stdin: invocation.stdin, stderrLimit: invocation.stderrLimit,
                        killGrace: killGrace, drainGrace: drainGrace,
                        onOutput: { continuation.yield(.output($0)) }, immediateCleanupOnExit: true
                    ))
                    let duration = started.duration(to: .now).components
                    continuation.yield(.finished(.init(
                        exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                        duration: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                        timedOut: result.termination == .timedOut, truncated: result.outputTruncated
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as AskWorkflowRunError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation
                        .finish(throwing: AskWorkflowRunError.spawnFailed(Int32(clamping: (error as NSError).code)))
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    task.cancel()
                }
            }
        }
    }
}
