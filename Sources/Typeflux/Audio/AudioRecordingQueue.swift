import Foundation

/// An incomplete file remains available for recovery, but is never a successful recording.
struct IncompleteAudioRecording: LocalizedError {
    let file: AudioFile
    let cause: Error
    var errorDescription: String? { "Recording is incomplete: \(cause.localizedDescription)" }
}

enum RecordingAudioQueueError: LocalizedError, Equatable {
    case capacityExceeded, invalidBuffer
    var errorDescription: String? {
        switch self {
        case .capacityExceeded: "Audio recording queue capacity exceeded."
        case .invalidBuffer: "Audio recording buffer is invalid or too large."
        }
    }
}

final class AudioBufferWriteAttempt: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var failure: Error?
    private var cancelled = false

    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    var mayWrite: Bool { lock.lock(); defer { lock.unlock() }; return failure == nil && !cancelled }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = error }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Reservations include conversion, queued buffers and the writer in flight.
/// Replacing an attempt never resets physical occupancy or retries entered writes.
final class AudioBufferWriteCoordinator: @unchecked Sendable {
    static let maximumBufferBytes = 256 * 1024
    private let queue = DispatchQueue(label: "typeflux.audio.buffer-writer")
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let maximumOperations: Int
    private let maximumBytes: Int
    private var operations = 0
    private var bytes = 0
    private var current = AudioBufferWriteAttempt()

    init(maximumOperations: Int = 64, maximumBytes: Int = 16 * 1024 * 1024) {
        self.maximumOperations = max(1, min(maximumOperations, 64))
        self.maximumBytes = max(1, min(maximumBytes, 16 * 1024 * 1024))
    }

    func beginAttempt() -> AudioBufferWriteAttempt {
        lock.lock(); defer { lock.unlock() }
        current.cancel()
        current = AudioBufferWriteAttempt()
        return current
    }

    func reserve(bytes: Int, attempt: AudioBufferWriteAttempt) -> Reservation? {
        lock.lock(); defer { lock.unlock() }
        guard current === attempt, attempt.mayWrite else { return nil }
        guard bytes > 0, bytes <= Self.maximumBufferBytes else {
            attempt.fail(RecordingAudioQueueError.invalidBuffer); return nil
        }
        guard operations < maximumOperations, bytes <= maximumBytes - self.bytes else {
            attempt.fail(RecordingAudioQueueError.capacityExceeded); return nil
        }
        operations += 1
        self.bytes += bytes
        group.enter()
        return Reservation(coordinator: self, attempt: attempt, bytes: bytes)
    }

    /// Compatibility for existing callers without a separate preparation allocation.
    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () -> Void) -> Bool {
        lock.lock(); let attempt = current; lock.unlock()
        guard let reservation = reserve(bytes: 1, attempt: attempt) else { return false }
        reservation.submit(operation)
        return true
    }

    func drain() { group.wait() }

    private func release(bytes: Int) {
        lock.lock()
        operations -= 1
        self.bytes -= bytes
        lock.unlock()
        group.leave()
    }

    final class Reservation: @unchecked Sendable {
        private let coordinator: AudioBufferWriteCoordinator
        private let attempt: AudioBufferWriteAttempt
        private let bytes: Int
        private let lock = NSLock()
        private var submitted = false
        private var released = false

        fileprivate init(coordinator: AudioBufferWriteCoordinator, attempt: AudioBufferWriteAttempt, bytes: Int) {
            self.coordinator = coordinator; self.attempt = attempt; self.bytes = bytes
        }

        deinit { finish() }

        private func finish() {
            lock.lock()
            guard !released else { lock.unlock(); return }
            released = true
            lock.unlock()
            coordinator.release(bytes: bytes)
        }

        func submit(_ operation: @escaping @Sendable () throws -> Void) {
            lock.lock()
            guard !submitted else { lock.unlock(); return }
            submitted = true
            lock.unlock()
            coordinator.queue.async { [self] in
                defer { finish() }
                guard attempt.mayWrite else { return }
                do { try operation() } catch { attempt.fail(error) }
            }
        }
    }
}
