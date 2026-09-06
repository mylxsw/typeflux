import AVFoundation
import Foundation

/// Joins first audio arrival with successful workflow setup without blocking either.
/// All mutable state is protected by the lock; callbacks run outside it.
final class RecordingAudioReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedAudio = false
    private var cancelled = false
    private var delivered = false
    private var handler: (() -> Void)?

    var isReady: Bool {
        lock.withLock { receivedAudio && !cancelled }
    }

    func receiveAudio(_ buffer: AVAudioPCMBuffer) {
        // Signal onset remains diagnostic; silence must not hold the recording UI.
        guard buffer.frameLength > 0 else { return }
        receiveAudio()
    }

    func receiveAudio() {
        let callback = lock.withLock {
            receivedAudio = true
            return takeHandlerIfReady()
        }
        callback?()
    }

    func whenReady(_ handler: @escaping () -> Void) {
        let callback: (() -> Void)? = lock.withLock {
            guard !cancelled, !delivered else { return nil }
            self.handler = handler
            return takeHandlerIfReady()
        }
        callback?()
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            handler = nil
        }
    }

    private func takeHandlerIfReady() -> (() -> Void)? {
        guard receivedAudio, !cancelled, !delivered, let handler else { return nil }
        delivered = true
        self.handler = nil
        return handler
    }
}
