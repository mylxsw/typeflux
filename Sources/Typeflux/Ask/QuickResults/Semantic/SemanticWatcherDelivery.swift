import Foundation

/// Delivers the highest event ID in one scheduled callback. The journal owns the file changes.
final class SemanticWatcherDelivery: @unchecked Sendable {
    final class Source: Sendable {
        let lifecycle: AskSearchCancellation
        init(lifecycle: AskSearchCancellation) { self.lifecycle = lifecycle }
    }
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private var source: Source?
    private var sink: (@MainActor @Sendable (UInt64) -> Void)?
    private var pendingEventID: UInt64?
    private var scheduled = false

    init(schedule: @escaping Schedule = { action in Task { @MainActor in action() } }) { self.schedule = schedule }

    @MainActor func begin(_ source: Source, sink: @escaping @MainActor @Sendable (UInt64) -> Void) {
        lock.withLock { self.source = source; self.sink = sink; pendingEventID = nil }
    }

    func offer(eventID: UInt64, from source: Source) {
        let enqueue = lock.withLock {
            guard self.source === source, !source.lifecycle.isCancelled else { return false }
            pendingEventID = max(pendingEventID ?? 0, eventID)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue { enqueueDelivery() }
    }

    func invalidate() { lock.withLock { source = nil; sink = nil; pendingEventID = nil } }
    private func enqueueDelivery() { schedule { [self] in deliver() } }

    @MainActor private func deliver() {
        let delivery = lock.withLock {
            let result = (pendingEventID, sink, source)
            pendingEventID = nil
            return result
        }
        if let eventID = delivery.0, delivery.2?.lifecycle.isCancelled == false { delivery.1?(eventID) }
        let enqueue = lock.withLock {
            if pendingEventID != nil { return true }
            scheduled = false
            return false
        }
        if enqueue { enqueueDelivery() }
    }
}
