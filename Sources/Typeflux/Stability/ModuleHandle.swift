import Foundation

/// Stable facade retained by callers while the supervisor replaces services.
/// There is intentionally no replay option: operation identity and durable
/// execution claims continue to belong to the feature's existing journal.
final class ModuleHandle<Service: Sendable>: Sendable {
    let supervisor: ModuleSupervisor<Service>

    init(policy: ModulePolicy = .init(),
         healthStore: ModuleHealthStore? = nil,
         factory: @escaping @Sendable () async throws -> Service,
         cleanup: @escaping @Sendable (Service) async -> Void = { _ in },
         classify: @escaping @Sendable (any Error) -> ModuleFailureDisposition = { _ in .recover },
         externalOperations: @escaping @Sendable () -> Int = { 0 },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        supervisor = ModuleSupervisor(policy: policy, healthStore: healthStore, factory: factory, cleanup: cleanup,
                                      classify: classify, externalOperations: externalOperations, uptime: uptime)
    }

    var health: ModuleHealthChannel { supervisor.healthChannel }
    func start() async throws { try await supervisor.perform { _ in () } }

    /// Only a deliberate user recovery action may clear persistent quarantine.
    func retry(resetPersistentBudget: Bool = false) async {
        await supervisor.retry(resetPersistentBudget: resetPersistentBudget)
    }

    deinit { supervisor.admission.shutdown() }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (Service) async throws -> Value) async throws -> Value {
        try await supervisor.perform(operation)
    }

    func setEnabled(_ enabled: Bool) async {
        supervisor.admission.setEnabled(enabled)
        await supervisor.setEnabled(enabled)
    }

    /// Fence synchronously before scheduling cleanup, even during process exit.
    func preventNewWork() { supervisor.admission.shutdown() }

    func shutdown() async {
        preventNewWork()
        await supervisor.shutdown()
    }
}
