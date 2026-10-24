import AppKit

@MainActor
enum ShortcutPanelPresentation {
    /// Order the nonactivating panel before changing keyboard focus. Focus
    /// notifications can update SwiftUI; those updates now target a visible window.
    /// Keep the native calls separate so diagnostics identify which one is slow.
    static func show(_ panel: NSWindow) {
        ShortcutLatency.measure(.windowOrderStarted, .windowOrderFinished) { panel.orderFront(nil) }
        ShortcutLatency.measure(.windowKeyStarted, .windowKeyFinished) {
            if !panel.isKeyWindow { panel.makeKey() }
        }
    }
}
