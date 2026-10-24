import AppKit
import QuartzCore

@MainActor
enum ShortcutPanelPresentation {
    /// Publish the first frame before the synchronous WindowServer focus request.
    /// Nonactivating panels must also rise above the source application's windows.
    static func show(_ panel: NSWindow) {
        ShortcutLatency.measure(.windowOrderStarted, .windowOrderFinished) { panel.orderFrontRegardless() }
        display([panel])
        ShortcutLatency.measure(.windowKeyStarted, .windowKeyFinished) {
            if !panel.isKeyWindow { panel.makeKey() }
        }
    }

    static func display(_ panels: [NSWindow]) {
        ShortcutLatency.measure(.windowDisplayStarted, .windowDisplayFinished) {
            for panel in panels { panel.displayIfNeeded() }
            // Layer-backed views otherwise wait for the end of this UI turn,
            // which makeKey() can hold up for hundreds of milliseconds.
            CATransaction.flush()
        }
    }
}
