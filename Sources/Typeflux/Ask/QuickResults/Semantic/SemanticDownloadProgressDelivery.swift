import Foundation

/// Replaceable absolute download progress only. One scheduled slot survives
/// cancellation/replacement, so a blocked UI never queues one task per byte event.
final class SemanticDownloadProgressDelivery: @unchecked Sendable {
    final class Source: Sendable {}
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private var source: Source?
    private var sink: (@MainActor @Sendable (Double) -> Void)?
    private var latest: Double?
    private var scheduled = false

    init(schedule: @escaping Schedule = { action in Task { @MainActor in action() } }) {
        self.schedule = schedule
    }

    @MainActor func begin(_ source: Source, sink: @escaping @MainActor @Sendable (Double) -> Void) {
        lock.withLock { self.source = source; self.sink = sink; latest = nil }
    }

    func offer(_ fraction: Double, from source: Source) {
        let enqueue = lock.withLock {
            guard self.source === source else { return false }
            latest = fraction
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue { enqueueDelivery() }
    }

    /// Seal before terminal state; progress has no effect on transfer or installation.
    func invalidate() {
        lock.withLock { source = nil; sink = nil; latest = nil }
    }

    private func enqueueDelivery() { schedule { [self] in deliver() } }

    @MainActor private func deliver() {
        let delivery = lock.withLock {
            let result = (latest, sink)
            latest = nil
            return result
        }
        if let fraction = delivery.0 { delivery.1?(fraction) }
        let enqueue = lock.withLock {
            if latest != nil { return true }
            scheduled = false
            return false
        }
        if enqueue { enqueueDelivery() }
    }
}
