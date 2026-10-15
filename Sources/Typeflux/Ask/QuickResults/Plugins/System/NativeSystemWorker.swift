import Darwin
import Foundation

@MainActor
protocol NativeSystemWorking {
    var isEnabled: Bool { get }
    func perform(_ operation: NativeSystemOperation) async throws
}

/// One independently owned native command at a time, with no queued mutations.
@MainActor
final class NativeSystemWorker: NativeSystemWorking {
    static let shared = NativeSystemWorker()
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let uptime: () -> TimeInterval
    private let run: @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result
    private var budget = ModuleRecoveryBudget()
    private var active: Task<ManagedProcess.Result, Error>?
    private var disabled = false
    private var previousChild: NativeSystemStartMarker?
    var isEnabled: Bool { !disabled }

    init(executable: URL = AskFileReader.executableURL, arguments: [String] = ["native-system-worker"],
         timeout: TimeInterval = 5, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         run: @escaping @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result = {
             try await ManagedProcess().run($0)
         }) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.uptime = uptime
        self.run = run
    }

    func preventNewWork() {
        disabled = true
        active?.cancel()
    }

    func shutdown() async {
        preventNewWork()
        _ = try? await active?.value
    }

    func perform(_ operation: NativeSystemOperation) async throws {
        guard !disabled else { throw NativeSystemFailure.disabled }
        guard !Task.isCancelled else { throw NativeSystemFailure.notExecuted }
        guard active == nil else { throw NativeSystemFailure.busy }
        guard previousChild?.awaitingRetirement != true else { throw NativeSystemFailure.busy }
        guard budget.permitsAttempt(at: uptime()) else { throw NativeSystemFailure.coolingDown }
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NativeSystemFailure.notExecuted }
        defer { close(directory) }
        let request = NativeSystemRequest(operation: operation)
        let started = NativeSystemStartMarker()
        previousChild = started
        let payload = try JSONEncoder().encode(request)
        let processRequest = ManagedProcess.Request(
            executable: executable.path, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            directoryDescriptor: directory, timeout: timeout, outputLimit: NativeSystemProtocol.maximumBytes,
            stopOnOutputLimit: true, preserveWhitespace: true, onStarted: { started.mark() }, stdin: payload,
            stderrLimit: 1024, immediateCleanupOnExit: true, onReaped: { started.retire() })
        let run = self.run
        let task = Task { try await run(processRequest) }
        active = task
        defer { active = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, !disabled, result.termination == .exited(0), !result.outputTruncated else {
                throw NativeSystemFailure.unknown
            }
            let outcome = try NativeSystemProtocol.decodeResponse(Data(result.stdout.utf8), for: request)
            switch outcome {
            case .completed: budget.succeeded(at: uptime())
            case .notExecuted: throw NativeSystemFailure.notExecuted
            case .unknown: throw NativeSystemFailure.unknown
            }
        } catch {
            budget.failed(at: uptime())
            if let failure = error as? NativeSystemFailure { throw failure }
            // No raw error/output escapes the child boundary. Never infer no effect
            // from an exit, malformed reply or cancellation after process launch.
            throw started.value ? NativeSystemFailure.unknown : NativeSystemFailure.notExecuted
        }
    }
}

private final class NativeSystemStartMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var retired = false
    func mark() { lock.withLock { started = true } }
    func retire() { lock.withLock { retired = true } }
    var value: Bool { lock.withLock { started } }
    var awaitingRetirement: Bool { lock.withLock { started && !retired } }
}
