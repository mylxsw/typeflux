import AppKit

/// Aligns the clipboard search card with the launcher's visible card while
/// keeping the clipboard centred horizontally and inside the usable screen.
enum ClipboardPanelPlacement {
    static func frame(size: NSSize, screen: NSRect, launcherAnchor: AskLauncherPlacement.Anchor? = nil) -> NSRect {
        // The launcher has a transparent gutter above its card; the clipboard does not.
        let top = AskLauncherPlacement.top(on: screen, anchor: launcherAnchor) - AskMetrics.launcherGutter
        let frame = NSRect(
            x: (screen.midX - size.width / 2).rounded(),
            y: top - size.height,
            width: size.width,
            height: size.height
        )
        return AskLauncherPlacement.clamped(frame, screen: screen)
    }

    /// The frame for the position chosen in settings: the launcher's top edge, the middle of the
    /// screen, or centered on the mouse pointer.
    static func frame(
        size: NSSize,
        screen: NSRect,
        position: ClipboardPanelPosition,
        launcherAnchor: AskLauncherPlacement.Anchor? = nil,
        mouse: NSPoint
    ) -> NSRect {
        switch position {
        case .launcher:
            return frame(size: size, screen: screen, launcherAnchor: launcherAnchor)
        case .screenCenter:
            let centered = NSRect(
                x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                width: size.width, height: size.height
            )
            return AskLauncherPlacement.clamped(centered, screen: screen)
        case .mouse:
            let centered = NSRect(
                x: (mouse.x - size.width / 2).rounded(), y: (mouse.y - size.height / 2).rounded(),
                width: size.width, height: size.height
            )
            return AskLauncherPlacement.clamped(centered, screen: screen)
        }
    }
}
