import Foundation

/// No payloads, tasks per request, or disk I/O in the synchronous admission path.
/// The latest signal cannot lose a fault: the fault token is retained separately.
final class ModuleWorkerGate: @unchecked Sendable {
    let admission: ModuleAdmission
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let health: ModuleHealthChannel
    private let store: ModuleHealthStore
    private let lock = NSLock()
    private var fault: UUID?
    private var disposition: ModuleFailureDisposition = .recover

    init(admission: ModuleAdmission, health: ModuleHealthChannel, store: ModuleHealthStore) {
        self.admission = admission; self.health = health; self.store = store
        (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var failure: (UUID?, ModuleFailureDisposition) { lock.withLock { (fault, disposition) } }
    func changed() { continuation.yield(()) }
    func finish() { continuation.finish() }

    func admit() throws -> UUID {
        guard admission.permitsWork, let snapshot = health.current, snapshot.state == .ready,
              lock.withLock({ fault != snapshot.generation }) else { throw ModuleFailure.unavailable }
        return snapshot.generation
    }

    func permits(_ generation: UUID?) -> Bool {
        guard let generation, let current = try? admit() else { return false }
        return current == generation
    }

    func failed(_ generation: UUID?, configuration: Bool) {
        guard let generation, permits(generation) else { return }
        lock.withLock {
            fault = generation; disposition = configuration ? .waitForExplicitRetry : .recover
            store.failed()
        }
        changed()
    }

    func succeeded(_ generation: UUID?) {
        guard let generation, admission.permitsWork, health.current?.generation == generation else { return }
        lock.withLock { if fault != generation { store.succeeded() } }
    }
}
