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
}
