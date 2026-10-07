import Foundation

/// Cancellation shared by the UI, GCD workers and the parallel file scan.
final class AskSearchCancellation: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    static func == (lhs: AskSearchCancellation, rhs: AskSearchCancellation) -> Bool { lhs === rhs }
}

/// One running operation and one replaceable pending operation. A slow provider
/// cannot create a queue of obsolete scans, even if it ignores cancellation.
@MainActor
final class AskSearchWorker<Value: Sendable> {
    private struct Job {
        let cancellation: AskSearchCancellation
        let operation: @Sendable (AskSearchCancellation) -> Value
        let completion: @MainActor (Value) -> Void
    }

    private let queue: DispatchQueue
    private var running: AskSearchCancellation?
    private var pending: Job?

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func submit(operation: @escaping @Sendable (AskSearchCancellation) -> Value,
                completion: @escaping @MainActor (Value) -> Void) {
        cancel()
        pending = Job(cancellation: AskSearchCancellation(), operation: operation, completion: completion)
        startNext()
    }

    func cancel() {
        running?.cancel()
        pending = nil
    }

    private func startNext() {
        guard running == nil, let job = pending else { return }
        pending = nil
        running = job.cancellation
        queue.async { [weak self] in
            let value = job.operation(job.cancellation)
            Task { @MainActor in
                guard let self else { return }
                self.running = nil
                if !job.cancellation.isCancelled { job.completion(value) }
                self.startNext()
            }
        }
    }

    deinit { running?.cancel() }
}
