import AVFoundation
import Foundation

/// Joins first audio arrival with successful workflow setup without blocking either.
/// All mutable state is protected by the lock; callbacks run outside it.
final class RecordingAudioReadiness: @unchecked Sendable {
    /// A Bluetooth headset switching to its call profile delivers 1-2 s of digital
    /// silence. Cap the wait so a muted or broken headset cannot hold the recording UI.
    static let defaultSignalWaitTimeout: TimeInterval = 2.5

    private let lock = NSLock()
    private let signalWaitTimeout: TimeInterval
    private var receivedAudio = false
    private var receivedSignal = false
    private var requiresSignal = false
    private var signalWaitExpired = false
    private var cancelled = false
    private var delivered = false
    private var handler: (() -> Void)?

    init(signalWaitTimeout: TimeInterval = RecordingAudioReadiness.defaultSignalWaitTimeout) {
        self.signalWaitTimeout = signalWaitTimeout
    }

    var isReady: Bool {
        lock.withLock { isReadyLocked }
    }

    func receiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // Digital zeros are not quiet speech: they mean the input is not delivering yet.
        // Ordinary quiet audio still counts as signal and never holds the UI.
        let needsScan = lock.withLock { !receivedSignal }
        receiveAudio(hasSignal: needsScan && AudioInputSignalTracker.firstNonzeroFrame(in: buffer) != nil)
    }

    func receiveAudio(hasSignal: Bool = false) {
        let callback = lock.withLock {
            receivedAudio = true
            receivedSignal = receivedSignal || hasSignal
            return takeHandlerIfReady()
        }
        callback?()
    }

    /// `requiringSignal` is for inputs known to start with digital silence (Bluetooth).
    /// Other inputs stay ready on their first buffer.
    func whenReady(requiringSignal: Bool = false, _ handler: @escaping () -> Void) {
        let (callback, startsSignalWait): ((() -> Void)?, Bool) = lock.withLock {
            guard !cancelled, !delivered else { return (nil, false) }
            self.handler = handler
            let startsSignalWait = requiringSignal && !requiresSignal
            requiresSignal = requiresSignal || requiringSignal
            return (takeHandlerIfReady(), startsSignalWait)
        }
        if startsSignalWait {
            let deadline = DispatchTime.now() + signalWaitTimeout
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self] in
                self?.expireSignalWait()
            }
        }
        callback?()
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            handler = nil
        }
    }

    private func expireSignalWait() {
        let callback: (() -> Void)? = lock.withLock {
            guard !receivedSignal, !cancelled, !delivered else { return nil }
            signalWaitExpired = true
            return takeHandlerIfReady()
        }
        if let callback {
            NetworkDebugLogger.logMessage(
                "[Audio Readiness] Input delivered no sound within \(signalWaitTimeout) s; showing recording anyway."
            )
            callback()
        }
    }

    private var isReadyLocked: Bool {
        receivedAudio && !cancelled && (!requiresSignal || receivedSignal || signalWaitExpired)
    }

    private func takeHandlerIfReady() -> (() -> Void)? {
        guard isReadyLocked, !delivered, let handler else { return nil }
        delivered = true
        self.handler = nil
        return handler
    }
}
