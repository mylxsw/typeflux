import Foundation

/// Unions work obligations, never replaces an event batch with the newest one.
/// Overflow retains a full-scope catch-up obligation and the highest event receipt.
final class SemanticWatcherDelivery: @unchecked Sendable {
    final class Source: Sendable {
        let scope: AskFileScope
        let indexDirectory: String
        let lifecycle: AskSearchCancellation
        init(scope: AskFileScope, indexDirectory: String, lifecycle: AskSearchCancellation) {
            self.scope = scope; self.indexDirectory = indexDirectory; self.lifecycle = lifecycle
        }
    }
    struct Snapshot: Sendable {
        var plan = SemanticFileChangePlan()
        var eventID: UInt64 = 0
    }
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private var source: Source?
    private var sink: (@MainActor @Sendable (Snapshot) -> Void)?
    private var pending: Snapshot?
    private var scheduled = false

    init(schedule: @escaping Schedule = { action in Task { @MainActor in action() } }) { self.schedule = schedule }

    @MainActor func begin(_ source: Source, sink: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        lock.withLock { self.source = source; self.sink = sink; pending = nil }
    }

    func offer(_ changes: [AskFileChange], eventID: UInt64, from source: Source) {
        guard lock.withLock({ self.source === source }), !source.lifecycle.isCancelled else { return }
        // Planning is pure path handling, outside the lock. No raw array is retained
        // by a UI task, and even one oversized producer batch has bounded scratch state.
        var plan = SemanticFileChangePlan()
        for change in changes {
            plan.mergeForHandoff(.make([change], scope: source.scope, indexDirectory: source.indexDirectory))
            if plan.fullScan { break }
        }
        let enqueue = lock.withLock {
            guard self.source === source, !source.lifecycle.isCancelled else { return false }
            var snapshot = pending ?? Snapshot()
            snapshot.plan.mergeForHandoff(plan)
            snapshot.eventID = max(snapshot.eventID, eventID)
            pending = snapshot
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue { enqueueDelivery() }
    }

    func invalidate() { lock.withLock { source = nil; sink = nil; pending = nil } }
    private func enqueueDelivery() { schedule { [self] in deliver() } }

    @MainActor private func deliver() {
        let delivery = lock.withLock {
            let result = (pending, sink, source); pending = nil; return result
        }
        if let snapshot = delivery.0, delivery.2?.lifecycle.isCancelled == false { delivery.1?(snapshot) }
        let enqueue = lock.withLock {
            if pending != nil { return true }
            scheduled = false
            return false
        }
        if enqueue { enqueueDelivery() }
    }
}
