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

    /// The top edge every launcher on `screen` shares: the empty one's, centred.
    static func top(on screen: NSRect) -> CGFloat {
        (screen.midY + restingHeight / 2).rounded()
    }

    static func frame(height: CGFloat, width: CGFloat, screen: NSRect) -> NSRect {
        let top = top(on: screen)
        return clamped(NSRect(x: (screen.midX - width / 2).rounded(), y: top - height, width: width, height: height),
                       screen: screen)
    }

    /// The same panel at a new height, its top edge at `top` (the edge it opened
    /// with) or else unchanged. Keeping the opening edge means a panel moved up to
    /// fit the screen returns to its place once it is short again.
    static func resized(_ frame: NSRect, height: CGFloat, top: CGFloat? = nil, screen: NSRect?) -> NSRect {
        let edge = top ?? frame.maxY
        let next = NSRect(x: frame.minX, y: edge - height, width: frame.width, height: height)
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
