import Foundation

/// Stable observation endpoint. Slow consumers retain only the latest snapshot;
/// abandoned subscriptions are bounded independently of operation admission.
final class ModuleHealthChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ModuleHealth?
    private var observers: [UUID: AsyncStream<ModuleHealth>.Continuation] = [:]

    var current: ModuleHealth? { lock.withLock { latest } }

    func observe() throws -> AsyncStream<ModuleHealth> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModuleHealth>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        let accepted = lock.withLock {
            guard observers.count < 16 else { return false }
            observers[id] = continuation
            if let latest { continuation.yield(latest) }
            return true
        }
        guard accepted else { continuation.finish(); throw ModuleFailure.overloaded }
        return stream
    }

    func publish(_ health: ModuleHealth) {
        lock.withLock {
            latest = health
            for observer in observers.values { observer.yield(health) }
        }
    }

    private func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
}
