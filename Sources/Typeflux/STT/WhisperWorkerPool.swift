import Foundation
import TypefluxInferenceProtocol

/// Independent inference admission. Preparation and the selected model may each
/// own one child; a timed-out child remains counted until confirmed retirement.
final class WhisperWorkerPool: @unchecked Sendable {
    static let shared = WhisperWorkerPool(requiresLifecycle: true)
    private let lock = NSLock()
    private var entries: [UUID: (paths: [String], stop: @Sendable () -> Void, generation: UUID?)] = [:]
    private var disabled = false
    private var lifecycle: ModuleWorkerGate?
    private var waiter: CheckedContinuation<Void, Never>?
    private let requiresLifecycle: Bool
    private let executable: URL
    private var budget = ModuleRecoveryBudget()
    private let uptime: @Sendable () -> TimeInterval

    init(executable: URL = WhisperWorkerClient.executableURL, requiresLifecycle: Bool = false, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime; self.executable = executable; self.requiresLifecycle = requiresLifecycle
    }

    func reserve(paths: [String], stop: @escaping @Sendable () -> Void) throws -> UUID {
        let id = try lock.withLock {
            guard !disabled else { throw InferenceFailure.unavailable }
            let generation: UUID?
            if let lifecycle {
                guard let value = try? lifecycle.admit() else { throw InferenceFailure.unavailable }
                generation = value
            } else {
                guard !requiresLifecycle, budget.permitsAttempt(at: uptime()) else { throw InferenceFailure.unavailable }
                generation = nil
            }
            guard entries.count < 2 else { throw InferenceFailure.busy }
            let id = UUID()
            entries[id] = (paths, stop, generation)
            return id
        }
        lock.withLock { lifecycle }?.changed()
        return id
    }

    func release(_ id: UUID, failed: Bool) {
        if failed { recordFailure(id) }
        let done: CheckedContinuation<Void, Never>? = lock.withLock {
            guard entries.removeValue(forKey: id) != nil, entries.isEmpty else { return nil }
            let done = waiter; waiter = nil; return done
        }
        lock.withLock { lifecycle }?.changed(); done?.resume()
    }

    func permits(_ id: UUID) -> Bool {
        lock.withLock {
            guard !disabled, let entry = entries[id] else { return false }
            return lifecycle.map { $0.permits(entry.generation) } ?? !requiresLifecycle
        }
    }

    func recordFailure(_ id: UUID, configuration: Bool = false) {
        lock.withLock {
            guard !disabled, let entry = entries[id] else { return }
            if let lifecycle { lifecycle.failed(entry.generation, configuration: configuration) }
            else { budget.failed(at: uptime()) }
        }
    }

    func succeeded(_ id: UUID) {
        lock.withLock {
            guard !disabled, let entry = entries[id] else { return }
            if let lifecycle { lifecycle.succeeded(entry.generation) }
            else { budget.succeeded(at: uptime()) }
        }
    }

    func bind(_ gate: ModuleWorkerGate) -> Bool {
        lock.withLock {
            guard lifecycle == nil, entries.isEmpty, !disabled else { return false }
            lifecycle = gate; return true
        }
    }

    func checkReadiness() async throws {
        let path = executable.path
        let available = await Task.detached(priority: .utility) { FileManager.default.isExecutableFile(atPath: path) }.value
        guard available, lock.withLock({ !disabled && entries.isEmpty }) else { throw ModuleFailure.unavailable }
    }

    func stopOwned() { lock.withLock { entries.values.map(\.stop) }.forEach { $0() } }

    func retireManaged() async {
        stopOwned()
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard !entries.isEmpty else { return true }
                waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
    }

    func checkUnused(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        try lock.withLock {
            guard !entries.values.contains(where: { entry in
                entry.paths.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
            }) else { throw InferenceFailure.busy }
        }
    }

    func preventNewWork() {
        let stops = lock.withLock {
            disabled = true
            lifecycle?.admission.shutdown()
            return entries.values.map(\.stop)
        }
        stops.forEach { $0() }
    }

    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lock.withLock({ !entries.isEmpty }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
        }
    }

    var activeCount: Int { lock.withLock { entries.count } }
}

/// Factory cancellation is synchronous, including while model loading is pending.
final class WhisperWorkerOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var client: WhisperWorkerClient?
    var permitsWork: Bool { lock.withLock { !stopped } }
    var canReuse: Bool { lock.withLock { !stopped && (client?.canReuse ?? true) } }
    func install(_ client: WhisperWorkerClient) throws {
        try lock.withLock {
            guard !stopped else { client.stop(); throw InferenceFailure.cancelled }
            self.client = client
        }
    }
    func stop() {
        let client = lock.withLock { stopped = true; return self.client }
        client?.stop()
    }
}
