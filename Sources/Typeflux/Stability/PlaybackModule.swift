import Foundation

/// Readiness restores admission only; it never loads media or replays controls.
final class PlaybackModule: @unchecked Sendable {
    let module: ModuleHandle<ClipboardPlaybackPool>
    private let pool: ClipboardPlaybackPool
    private let gate: ModuleWorkerGate
    private let ownsPool: Bool
    private let observation: Task<Void, Never>

    init(pool: ClipboardPlaybackPool, healthDirectory: URL, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pool = pool
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent("mediaPlayback.json"), uptime: uptime)
        let module = ModuleHandle<ClipboardPlaybackPool>(policy: policy, healthStore: store,
            factory: { try await pool.checkReadiness(); return pool }, cleanup: { await $0.retireManaged() },
            classify: { _ in .waitForExplicitRetry }, externalOperations: { pool.activeCount }, uptime: uptime)
        self.module = module
        let gate = ModuleWorkerGate(admission: module.supervisor.admission, health: module.health, store: store)
        self.gate = gate
        ownsPool = pool.bind(gate)
        if !ownsPool { module.preventNewWork() }
        observation = Task { [supervisor = module.supervisor, gate] in
            for await _ in gate.events {
                guard !Task.isCancelled else { return }
                let failure = gate.failure
                await supervisor.externalActivity(failedGeneration: failure.0, disposition: failure.1)
            }
        }
    }
    var registration: ModuleRegistration { .init(.mediaPlayback, handle: module) }
    deinit {
        module.preventNewWork()
        if ownsPool { pool.stopOwned() }
        gate.finish(); observation.cancel()
    }
}
