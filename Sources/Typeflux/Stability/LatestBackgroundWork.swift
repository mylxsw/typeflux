import Foundation

enum BackgroundWorkFailure: Error, Equatable { case cancelled, timedOut }

protocol LatestBackgroundWorking: AnyObject {
    func submit(_ work: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}

/// For synchronous APIs that cannot be interrupted. At most one running and one
/// replacement request are retained. A timeout releases the caller, never the
/// occupied worker slot. No synchronous dispatch or wait is exposed to the UI.
final class LatestBackgroundWork: LatestBackgroundWorking, @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let work: () -> Void
        private let lock = NSLock()
        private var completion: ((Result<Void, Error>) -> Void)?
        private var timer: DispatchWorkItem?

        init(work: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            self.work = work; self.completion = completion
        }

        var isPending: Bool { lock.withLock { completion != nil } }

        func expire(after timeout: TimeInterval) {
            let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(BackgroundWorkFailure.timedOut)) }
            lock.withLock { if completion != nil { self.timer = timer } else { timer.cancel() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        }

        func finish(_ result: Result<Void, Error>) {
            let callback = lock.withLock {
                let value = completion; completion = nil
                timer?.cancel(); timer = nil
                return value
            }
            if let callback { DispatchQueue.main.async { callback(result) } }
        }
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private var active: Job?
    private var pending: Job?

    init(label: String, timeout: TimeInterval = 5, queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(label: label, qos: .userInitiated)
        self.timeout = timeout
    }

    func submit(_ work: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        let job = Job(work: work, completion: completion)
        let displaced: Job? = lock.withLock {
            let old = pending
            pending = job
            return old
        }
        displaced?.finish(.failure(BackgroundWorkFailure.cancelled))
        job.expire(after: timeout)
        startNext()
    }

    func cancel() {
        let jobs: [Job] = lock.withLock {
            defer { pending = nil }
            return [active, pending].compactMap { $0 }
        }
        for job in jobs { job.finish(.failure(BackgroundWorkFailure.cancelled)) }
    }

    private func startNext() {
        let job: Job? = lock.withLock {
            guard active == nil, let next = pending else { return nil }
            pending = nil; active = next
            return next
        }
        guard let job else { return }
        queue.async { [self] in
            if job.isPending { job.work() }
            job.finish(.success(()))
            lock.withLock { active = nil }
            startNext()
        }
    }
}
