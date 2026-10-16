import Foundation

/// Supervises capability only. Typed command execution and unknown outcomes
/// remain in the existing worker; no command is a factory or readiness probe.
@MainActor
final class NativeSystemModule {
    let module: ModuleHandle<NativeSystemWorker>
    private let gate: ModuleWorkerGate
    private let activity: NativeSystemActivity
    private let observation: Task<Void, Never>

    init(worker: NativeSystemWorker, healthDirectory: URL, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent("nativeSystem.json"), uptime: uptime)
        let module = ModuleHandle<NativeSystemWorker>(policy: policy, healthStore: store,
            factory: { try await worker.checkReadiness(); return worker },
            cleanup: { await $0.retireManaged() }, classify: { _ in .waitForExplicitRetry },
            externalOperations: { worker.activeCount }, uptime: uptime)
        self.module = module; activity = worker.activity
        let gate = ModuleWorkerGate(admission: module.supervisor.admission, health: module.health, store: store)
        self.gate = gate
        if !worker.bind(gate) { module.preventNewWork() }
        observation = Task { [supervisor = module.supervisor, gate] in
            for await _ in gate.events {
                guard !Task.isCancelled else { return }
                let failure = gate.failure
                await supervisor.externalActivity(failedGeneration: failure.0, disposition: failure.1)
            }
        }
    }
    var registration: ModuleRegistration { .init(.nativeSystem, handle: module) }
    deinit { module.preventNewWork(); activity.stop(); gate.finish(); observation.cancel() }
}

/// One slot survives BOTH host completion and confirmed collection. UUID fencing
/// makes a duplicate late reaper harmless after a later explicit operation starts.
final class NativeSystemActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var launched = false, collected = false, finished = false, stopped = false
    private var cancel: (@Sendable () -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    private var signal: (@Sendable () -> Void)?
    var changed: (@Sendable () -> Void)? {
        get { lock.withLock { signal } }
        set { lock.withLock { signal = newValue } }
    }
    var count: Int { lock.withLock { token == nil ? 0 : 1 } }
    func begin(_ id: UUID) {
        lock.withLock { token = id; launched = false; collected = false; finished = false; stopped = false; cancel = nil }
        changed?()
    }
    func installCancellation(_ id: UUID, _ action: @escaping @Sendable () -> Void) {
        let stopNow = lock.withLock {
            guard token == id, !stopped else { return true }
            cancel = action; return false
        }
        if stopNow { action() }
    }
    func stop() {
        let action = lock.withLock { stopped = true; return cancel }
        action?()
    }
    func started(_ id: UUID) { update(id) { launched = true } }
    func reaped(_ id: UUID) { update(id) { collected = true } }
    func returned(_ id: UUID) { update(id) { finished = true } }
    private func update(_ id: UUID, _ body: () -> Void) {
        let done: CheckedContinuation<Void, Never>? = lock.withLock {
            guard token == id else { return nil }
            body()
            guard finished, !launched || collected else { return nil }
            token = nil; cancel = nil
            let done = waiter; waiter = nil; return done
        }
        changed?(); done?.resume()
    }
    func waitForRetirement() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard token != nil else { return true }
                // One supervisor cleanup owns this wait, including after timeout.
                waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
    }
}
