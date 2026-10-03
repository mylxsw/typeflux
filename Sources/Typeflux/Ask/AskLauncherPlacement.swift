import AppKit

/// Where the ⌥Space launcher sits: centred on the screen like Spotlight. Its top
/// edge stays put while it grows, so a longer question or the suggestion list
/// opens downward instead of pushing the input field up.
enum AskLauncherPlacement {
    /// Keeps the panel this far from the screen's usable edges.
    static let screenMargin: CGFloat = 12

    /// The empty launcher, suggestions included, is centred on the screen.
    static var restingHeight: CGFloat {
        AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: true)
    }

    static func frame(height: CGFloat, width: CGFloat, screen: NSRect) -> NSRect {
        let top = (screen.midY + restingHeight / 2).rounded()
        return clamped(NSRect(x: (screen.midX - width / 2).rounded(), y: top - height, width: width, height: height),
                       screen: screen)
    }

    /// The same panel at a new height, its top edge unchanged.
    static func resized(_ frame: NSRect, height: CGFloat, screen: NSRect?) -> NSRect {
        let next = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        guard let screen else { return next }
        return clamped(next, screen: screen)
    }

    /// Never past the bottom of the usable screen: a very tall panel moves up instead.
    static func clamped(_ frame: NSRect, screen: NSRect) -> NSRect {
        var result = frame
        if result.minY < screen.minY + screenMargin { result.origin.y = screen.minY + screenMargin }
        if result.maxY > screen.maxY - screenMargin {
            result.origin.y = max(screen.minY + screenMargin, screen.maxY - screenMargin - result.height)
        }
        return result
    }
}
