import AppKit

/// Keeps the first presentation of a window inside the visible area of its screen, so a window
/// designed for a larger display does not start partly off-screen on a small one.
enum WindowScreenFitting {
    /// `frame`, shrunk where it is larger than `visibleFrame` and moved inside it.
    static func frame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        let size = self.size(frame.size, within: visibleFrame)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    /// Also used for minimum sizes: a minimum larger than the screen would block the fit.
    static func size(_ size: NSSize, within visibleFrame: NSRect) -> NSSize {
        NSSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
    }
}
