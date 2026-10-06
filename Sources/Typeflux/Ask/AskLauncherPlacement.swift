import AppKit

/// Where the ⌥Space launcher sits: centred on the screen like Spotlight, or where
/// the user last dragged it on that screen. Its top edge stays put while it grows,
/// so a longer question or the suggestion list opens downward instead of pushing
/// the input field up.
enum AskLauncherPlacement {
    /// Keeps the panel this far from the screen's usable edges.
    static let screenMargin: CGFloat = 12
    /// A panel dragged this close to the screen's vertical centre line snaps onto it.
    static let snapDistance: CGFloat = 8

    /// A remembered position: the panel's top-left corner, measured from the
    /// top-left of the screen's usable area, so it survives the Dock or menu bar
    /// changing size and screens being rearranged.
    struct Anchor: Equatable, Codable, Sendable {
        var left: CGFloat
        var fromTop: CGFloat
    }

    /// The empty launcher, suggestions included, is centred on the screen.
    static var restingHeight: CGFloat {
        AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: true)
    }

    /// The top edge every launcher on `screen` shares: the empty one's, centred,
    /// or the remembered one's.
    static func top(on screen: NSRect, anchor: Anchor? = nil) -> CGFloat {
        guard let anchor else { return (screen.midY + restingHeight / 2).rounded() }
        return (screen.maxY - anchor.fromTop).rounded()
    }

    static func frame(height: CGFloat, width: CGFloat, screen: NSRect, anchor: Anchor? = nil) -> NSRect {
        let top = top(on: screen, anchor: anchor)
        let left = anchor.map { screen.minX + $0.left } ?? screen.midX - width / 2
        return clamped(NSRect(x: left.rounded(), y: top - height, width: width, height: height), screen: screen)
    }

    /// Where `frame` sits on `screen`, to open there next time.
    static func anchor(of frame: NSRect, on screen: NSRect) -> Anchor {
        Anchor(left: (frame.minX - screen.minX).rounded(), fromTop: (screen.maxY - frame.maxY).rounded())
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

    /// Never past the edges of the usable screen: a very tall panel moves up instead.
    static func clamped(_ frame: NSRect, screen: NSRect) -> NSRect {
        var result = frame
        if result.minY < screen.minY + screenMargin { result.origin.y = screen.minY + screenMargin }
        if result.maxY > screen.maxY - screenMargin {
            result.origin.y = max(screen.minY + screenMargin, screen.maxY - screenMargin - result.height)
        }
        if result.maxX > screen.maxX - screenMargin { result.origin.x = screen.maxX - screenMargin - result.width }
        if result.minX < screen.minX + screenMargin { result.origin.x = screen.minX + screenMargin }
        return result
    }

    /// Where a panel being dragged to `origin` goes: onto the screen's centre line
    /// when it is within `snapDistance` of it.
    static func snapped(origin: NSPoint, width: CGFloat, screen: NSRect) -> NSPoint {
        let centred = (screen.midX - width / 2).rounded()
        guard abs(origin.x - centred) <= snapDistance else { return origin }
        return NSPoint(x: centred, y: origin.y)
    }

    /// A stable name for a display, so each one keeps its own launcher position.
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        let display = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let name = CFUUIDCreateString(nil, uuid) as String? else {
            return "display-\(display)"
        }
        return name
    }
}

/// Whether the launcher opens centred or where it was last dragged.
enum AskLauncherPosition: String, CaseIterable, Sendable {
    case center
    case lastPosition
}
