import AppKit

/// A background presentation may take keyboard focus when it replaces its own
/// focused window or no visible key window remains. User-triggered openings
/// request focus explicitly.
@MainActor
enum KeyboardFocusPolicy {
    static func shouldFocusReplacement(of previous: NSWindow?) -> Bool {
        shouldFocusReplacement(of: previous, keyWindow: NSApp.keyWindow)
    }

    static func shouldFocusReplacement(of previous: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let keyWindow, keyWindow.isVisible else { return true }
        return keyWindow === previous
    }

    static func focusOnMouseDown(_ event: NSEvent, in window: NSWindow) {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              window.canBecomeKey, !window.isKeyWindow else { return }
        window.makeKey()
    }

    static func showWithoutTakingFocus(_ window: NSWindow) {
        guard !window.isVisible else { return }
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, keyWindow !== window {
            window.order(.below, relativeTo: keyWindow.windowNumber)
        } else {
            window.orderFrontRegardless()
        }
    }
}
