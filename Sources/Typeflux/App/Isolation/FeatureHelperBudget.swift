import Foundation

/// Shared by embedding models and media decoders in the
/// service process. A cancelled child still owns its slot until actual reaping.
final class FeatureHelperBudget: @unchecked Sendable {
    static let shared = FeatureHelperBudget(limit: 3)
    private let condition = NSCondition()
    private let limit: Int
    private var occupied = 0
    init(limit: Int) {
        self.limit = limit
    }

    var activeCount: Int {
        condition.lock(); defer { condition.unlock() }; return occupied
    }

    func acquire(deadline: Date, cancelled: () -> Bool) throws -> Lease {
        // Cancellation may call back into an owner; do not call it under this lock.
        while true {
            if cancelled() || Date() >= deadline {
                throw CancellationError()
            }
            condition.lock()
            if occupied < limit {
                occupied += 1; condition.unlock()
                return Lease { [self] in
                    condition.lock(); occupied -= 1; condition.broadcast(); condition.unlock()
                }
            }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.02)))
            condition.unlock()
        }
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var release: (@Sendable () -> Void)?
        init(_ release: @escaping @Sendable () -> Void) {
            self.release = release
        }

        func finish() {
            let action = lock.withLock { let action = release; release = nil; return action }; action?()
        }

        deinit { finish() }
    }
}
