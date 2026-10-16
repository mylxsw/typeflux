import Foundation

/// Readiness restores admission only; it never prepares a model or replays audio.
final class WhisperInferenceModule: @unchecked Sendable {
    let module: ModuleHandle<WhisperWorkerPool>
    private let pool: WhisperWorkerPool
    private let gate: ModuleWorkerGate
    private let ownsPool: Bool
    private let observation: Task<Void, Never>

    init(pool: WhisperWorkerPool, healthDirectory: URL, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pool = pool
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent("whisperInference.json"), uptime: uptime)
        let module = ModuleHandle<WhisperWorkerPool>(policy: policy, healthStore: store,
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
    var registration: ModuleRegistration { .init(.whisperInference, handle: module) }
    deinit {
        module.preventNewWork()
        if ownsPool { pool.stopOwned() }
        gate.finish(); observation.cancel()
    }
}
