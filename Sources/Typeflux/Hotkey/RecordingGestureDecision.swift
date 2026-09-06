import Foundation

/// Buffers microphone startup until the shared shortcut has selected a mode.
/// The stream also releases startup promptly when a recording is cancelled.
final class RecordingGestureDecision {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var timer: DispatchWorkItem?
    private var generation = 0
    private var resolved = false

    init() {
        var captured: AsyncStream<Void>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func schedule(after delay: TimeInterval) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        timer?.cancel()
        generation += 1
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            self?.resolve(generation: expectedGeneration)
        }
        timer = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    func resolve() {
        resolve(generation: nil)
    }

    private func resolve(generation expected: Int?) {
        lock.lock()
        guard !resolved, expected == nil || expected == generation else {
            lock.unlock()
            return
        }
        resolved = true
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation.yield(())
        continuation.finish()
    }

    func wait() async {
        for await _ in stream { return }
    }
}
