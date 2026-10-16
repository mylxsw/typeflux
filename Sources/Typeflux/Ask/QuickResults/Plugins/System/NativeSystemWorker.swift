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
    static let shared = NativeSystemWorker(requiresLifecycle: true)
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let uptime: () -> TimeInterval
    private let run: @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result
    private var budget = ModuleRecoveryBudget()
    private var active: Task<ManagedProcess.Result, Error>?
    private var disabled = false
    private let requiresLifecycle: Bool
    private var lifecycle: ModuleWorkerGate?
    nonisolated let activity = NativeSystemActivity()
    nonisolated var activeCount: Int { activity.count }
    var isEnabled: Bool { !disabled }

    init(executable: URL = AskFileReader.executableURL, arguments: [String] = ["native-system-worker"],
         timeout: TimeInterval = 5, requiresLifecycle: Bool = false, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         run: @escaping @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result = {
             try await ManagedProcess().run($0)
         }) {
        self.requiresLifecycle = requiresLifecycle
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.uptime = uptime
        self.run = run
    }

    func preventNewWork() {
        disabled = true
        lifecycle?.admission.shutdown()
        active?.cancel()
    }

    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCount > 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func bind(_ gate: ModuleWorkerGate) -> Bool {
        guard lifecycle == nil, activeCount == 0, !disabled else { return false }
        lifecycle = gate; activity.changed = { gate.changed() }; return true
    }

    func checkReadiness() async throws {
        let path = executable.path
        let available = await Task.detached(priority: .utility) { FileManager.default.isExecutableFile(atPath: path) }.value
        guard available, !disabled, activeCount == 0 else { throw ModuleFailure.unavailable }
    }

    func retireManaged() async {
        active?.cancel()
        await activity.waitForRetirement()
    }

    func perform(_ operation: NativeSystemOperation) async throws {
        guard !disabled else { throw NativeSystemFailure.disabled }
        guard !Task.isCancelled else { throw NativeSystemFailure.notExecuted }
        guard active == nil else { throw NativeSystemFailure.busy }
        guard activeCount == 0 else { throw NativeSystemFailure.busy }
        let gate = lifecycle, generation: UUID?
        if let gate {
            guard gate.admission.permitsWork else { throw NativeSystemFailure.disabled }
            guard let admitted = try? gate.admit() else { throw NativeSystemFailure.coolingDown }
            generation = admitted
        } else {
            guard !requiresLifecycle else { throw NativeSystemFailure.disabled }
            guard budget.permitsAttempt(at: uptime()) else { throw NativeSystemFailure.coolingDown }
            generation = nil
        }
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NativeSystemFailure.notExecuted }
        defer { close(directory) }
        let request = NativeSystemRequest(operation: operation)
        let started = NativeSystemStartMarker()
        let activity = self.activity, token = request.requestID
        activity.begin(token)
        defer { activity.returned(token) }
        let payload = try JSONEncoder().encode(request)
        let processRequest = ManagedProcess.Request(
            executable: executable.path, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            directoryDescriptor: directory, timeout: timeout, outputLimit: NativeSystemProtocol.maximumBytes,
            stopOnOutputLimit: true, preserveWhitespace: true, onStarted: { started.mark(); activity.started(token) }, stdin: payload,
            stderrLimit: 1024, immediateCleanupOnExit: true, onReaped: { activity.reaped(token) })
        let run = self.run
        let task = Task {
            guard !Task.isCancelled, gate == nil || gate!.permits(generation) else { throw NativeSystemFailure.notExecuted }
            return try await run(processRequest)
        }
        active = task
        activity.installCancellation(token) { task.cancel() }
        defer { active = nil }
        var infrastructureFailed = false, configurationFailure = false
        do {
            let result: ManagedProcess.Result
            do { result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
            catch {
                infrastructureFailed = true
                let code = error as NSError
                configurationFailure = code.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOEXEC)].contains(code.code)
                throw error
            }
            guard !Task.isCancelled, !disabled, gate == nil || gate!.permits(generation) else {
                throw started.value ? NativeSystemFailure.unknown : .notExecuted
            }
            guard result.termination == .exited(0), !result.outputTruncated else {
                infrastructureFailed = true; throw NativeSystemFailure.unknown
            }
            let outcome: NativeSystemOutcome
            do { outcome = try NativeSystemProtocol.decodeResponse(Data(result.stdout.utf8), for: request) }
            catch { infrastructureFailed = true; throw error }
            switch outcome {
            case .completed:
                if let gate { gate.succeeded(generation) } else { budget.succeeded(at: uptime()) }
            case .notExecuted: throw NativeSystemFailure.notExecuted
            case .unknown: throw NativeSystemFailure.unknown
            }
        } catch {
            if let gate {
                if infrastructureFailed, !Task.isCancelled, !disabled { gate.failed(generation, configuration: configurationFailure) }
            } else { budget.failed(at: uptime()) }
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
    func mark() { lock.withLock { started = true } }
    var value: Bool { lock.withLock { started } }
}
