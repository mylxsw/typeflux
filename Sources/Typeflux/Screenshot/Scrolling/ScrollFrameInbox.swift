import CoreGraphics
import Foundation

/// One latest frame and one scheduled delivery, including while the main actor is busy.
final class ScrollFrameInbox: @unchecked Sendable {
    struct Frame {
        let image: CGImage
        let viewport: CGImage?
    }

    private let lock = NSLock()
    private var frame: Frame?
    private var scheduled = false
    private var closed = false
    func offer(_ value: CGImage) -> Bool {
        guard value.width > 0, value.height > 0, value.width <= 16384,
              value.height <= 16384, value.width <= 16_000_000 / value.height else { return false }
        let viewport = DirectionalScrollStitcher.viewportThumbnail(of: value)
        return lock.withLock {
            guard !closed else { return false }
            frame = Frame(image: value, viewport: viewport)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }
    func take() -> Frame? {
        lock.withLock {
            defer { frame = nil; scheduled = false }
            return closed ? nil : frame
        }
    }
    func fail() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            closed = true; frame = nil
            return true
        }
    }
    func close() { lock.withLock { closed = true; frame = nil } }
}
