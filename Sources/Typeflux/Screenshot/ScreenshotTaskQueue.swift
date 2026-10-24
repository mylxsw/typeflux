import Foundation

/// Screenshots keep one capture operation in flight and only the
/// newest pending request. Cancelling a caller releases it immediately, but the
/// slot stays occupied until the system callback returns, even if it ignores cancellation.
@MainActor
final class ScreenshotTaskQueue<Value> {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    private final class Work {
        let cancellation = Cancellation()
        let operation: @MainActor () async throws -> Value
        let trace = ShortcutLatency.current
        let sink = ShortcutLatency.eventSink
        var continuation: CheckedContinuation<Value, Error>?
        var task: Task<Void, Never>?

        init(operation: @escaping @MainActor () async throws -> Value) { self.operation = operation }

        func record(_ stage: ShortcutLatencyStage) {
            ShortcutLatency.$eventSink.withValue(sink) { ShortcutLatency.record(stage, trace: trace) }
        }

        func finish(_ result: Result<Value, Error>) {
            let waiter = continuation
            continuation = nil
            waiter?.resume(with: result)
        }
    }

    private var active: Work?
    private var pending: Work?

    func capture(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let work = Work(operation: operation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                work.continuation = continuation
                guard !work.cancellation.isCancelled else {
                    work.record(.captureCancelled)
                    work.finish(.failure(CancellationError()))
                    return
                }
                work.record(.captureQueued)
                if let active {
                    cancel(active, stage: .captureSuperseded)
                    if let pending { cancel(pending, stage: .captureSuperseded) }
                    pending = work
                } else {
                    start(work)
                }
            }
        } onCancel: {
            work.cancellation.cancel()
            Task { @MainActor in self.cancel(work, stage: .captureCancelled) }
        }
    }

    private func cancel(_ work: Work, stage: ShortcutLatencyStage) {
        work.cancellation.cancel()
        work.task?.cancel()
        if work.continuation != nil { work.record(stage) }
        work.finish(.failure(CancellationError()))
        if pending === work { pending = nil }
    }

    private func start(_ work: Work) {
        guard !work.cancellation.isCancelled else {
            work.finish(.failure(CancellationError()))
            return
        }
        active = work
        work.task = Task {
            await ShortcutLatency.$eventSink.withValue(work.sink) {
                await ShortcutLatency.$current.withValue(work.trace) {
                    work.record(.captureDequeued)
                    let result: Result<Value, Error>
                    do {
                        try Task.checkCancellation()
                        if work.cancellation.isCancelled { throw CancellationError() }
                        let image = try await work.operation()
                        work.record(.captureReturned)
                        try Task.checkCancellation()
                        if work.cancellation.isCancelled { throw CancellationError() }
                        result = .success(image)
                    } catch {
                        result = .failure(error)
                    }
                    if work.cancellation.isCancelled { work.record(.captureDiscarded) }
                    work.record(.capturePublished)
                    work.finish(result)
                }
            }
            work.task = nil
            active = nil
            if let next = pending {
                pending = nil
                start(next)
            }
        }
    }
}
