import CoreGraphics
import Foundation

/// One latest frame and one scheduled delivery, including while the main actor is busy.
final class ScrollFrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var scheduled = false
    private var closed = false
    func offer(_ value: CGImage) -> Bool {
        lock.withLock {
            guard !closed, value.width > 0, value.height > 0, value.width <= 16384,
                  value.height <= 16384, value.width <= 16_000_000 / value.height else { return false }
            image = value
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }
    func take() -> CGImage? {
        lock.withLock {
            defer { image = nil; scheduled = false }
            return closed ? nil : image
        }
    }
    func fail() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            closed = true; image = nil
            return true
        }
    }
    func close() { lock.withLock { closed = true; image = nil } }
}
