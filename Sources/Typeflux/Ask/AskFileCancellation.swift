import Foundation

/// Owned by the trusted host (or one direct synchronous mutation). Cancellation
/// may race registration, but never calls Foundation while holding our lock.
final class AskFileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func cancel() {
        lock.lock()
        cancelled = true
        let active = coordinator
        lock.unlock()
        active?.cancel()
    }

    func check() throws {
        try Task.checkCancellation()
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value {
            throw CancellationError()
        }
    }

    func register(_ value: NSFileCoordinator) throws {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled {
            coordinator = value
        }
        lock.unlock()
        if wasCancelled {
            value.cancel()
            throw CancellationError()
        }
    }

    func unregister() {
        lock.lock()
        coordinator = nil
        lock.unlock()
    }

    /// Synchronous callers have no async cancellation-handler boundary. Observe
    /// their task only within withUnsafeCurrentTask's lifetime. The timer is
    /// cancelled AND drained before returning; no observer outlives the call.
    func observingTask<T>(_ body: () throws -> T) rethrows -> T {
        try withUnsafeCurrentTask { task in
            guard let task else { return try body() }
            let queue = DispatchQueue(label: "ai.typeflux.files.cancellation")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler {
                if task.isCancelled {
                    self.cancel()
                }
            }
            let drained = DispatchSemaphore(value: 0)
            timer.setCancelHandler { drained.signal() }
            timer.resume()
            defer {
                timer.cancel()
                drained.wait()
            }
            return try body()
        }
    }
}

/// A bounded wait retains serialization across aliases and overlapping grants.
/// A cancelled waiter never needs the current writer to leave its accessor.
final class AskFileMutationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var occupied = false

    func enter(cancellation: AskFileCancellation, onWait: (() throws -> Void)?) throws {
        condition.lock()
        defer { condition.unlock() }
        var observed = false
        while occupied {
            try cancellation.check()
            if !observed {
                observed = true
                condition.unlock()
                do { try onWait?() } catch { condition.lock(); throw error }
                condition.lock()
                continue
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try cancellation.check()
        occupied = true
    }

    func leave() {
        condition.lock()
        occupied = false
        condition.broadcast()
        condition.unlock()
    }
}
