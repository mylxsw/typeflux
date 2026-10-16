import Foundation

/// One mailbox per service, shared across attempts. Only replaceable UI snapshots
/// belong here; indexing, writes and watcher events never run through this mailbox.
final class SemanticIndexProgressDelivery: @unchecked Sendable {
    final class Source: Sendable {}
    struct Snapshot: Sendable {
        var summary: SemanticFileIndexer.Summary?
        var hasPath = false
        var path: String?
        var hasDownload = false
        var download: Double?
    }
    enum Update: Sendable {
        case summary(SemanticFileIndexer.Summary), path(String?), download(Double?)
    }
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private var source: Source?
    private var sink: (@MainActor @Sendable (Snapshot) -> Void)?
    private var pending: Snapshot?
    // Remains set through delivery, including invalidation/replacement. A blocked
    // main actor cannot accumulate one queued task per callback or per attempt.
    private var scheduled = false

    init(schedule: @escaping Schedule = { action in Task { @MainActor in action() } }) {
        self.schedule = schedule
    }

    @MainActor func begin(_ source: Source, sink: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        lock.withLock { self.source = source; self.sink = sink; pending = nil }
    }

    func offer(_ update: Update, from source: Source) {
        let enqueue = lock.withLock {
            guard self.source === source else { return false }
            var snapshot = pending ?? Snapshot()
            switch update {
            case let .summary(value): snapshot.summary = value
            case let .path(value): snapshot.hasPath = true; snapshot.path = value
            case let .download(value): snapshot.hasDownload = true; snapshot.download = value
            }
            pending = snapshot
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue { enqueueDelivery() }
    }

    /// Seal before publishing terminal state, and synchronously collect the last
    /// snapshot. A previously queued delivery cannot overwrite that terminal state.
    @MainActor func finish(_ source: Source) -> Snapshot? {
        lock.withLock {
            guard self.source === source else { return nil }
            let snapshot = pending
            self.source = nil; sink = nil; pending = nil
            return snapshot
        }
    }

    func invalidate() {
        lock.withLock { source = nil; sink = nil; pending = nil }
    }

    private func enqueueDelivery() {
        schedule { [self] in deliver() }
    }

    @MainActor private func deliver() {
        let delivery = lock.withLock {
            let result = (pending, sink)
            pending = nil
            return result
        }
        if let snapshot = delivery.0 { delivery.1?(snapshot) }
        let enqueue = lock.withLock {
            if pending != nil { return true }
            scheduled = false
            return false
        }
        if enqueue { enqueueDelivery() }
    }
}
