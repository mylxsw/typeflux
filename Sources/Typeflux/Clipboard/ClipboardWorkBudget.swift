import Foundation

/// Limits retained clipboard snapshots and invalidates queued work on stop.
final class ClipboardWorkBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumPending: Int
    private var pending = 0
    private var generation = UUID()

    init(maximumPending: Int = 2) {
        self.maximumPending = maximumPending
    }

    func reserve() -> UUID? {
        lock.withLock {
            guard pending < maximumPending else { return nil }
            pending += 1
            return generation
        }
    }

    func release() {
        lock.withLock { pending -= 1 }
    }

    func invalidate() {
        lock.withLock { generation = UUID() }
    }

    func accepts(_ token: UUID) -> Bool {
        lock.withLock { token == generation }
    }
}
