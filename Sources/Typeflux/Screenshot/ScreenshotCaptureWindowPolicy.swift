import AppKit

/// Capture controls should not cover the page being reported or feed back into a live capture.
enum ScreenshotCaptureWindowPolicy {
    static let toastIdentifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.screenshot-toast")
    static let permissionIdentifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.screenshot-permission")

    @MainActor
    static func excludes(_ window: NSWindow) -> Bool {
        window is ScreenshotOverlayPanel || window is ScreenshotFloatingPanel || window is ScreenshotPinPanel
            || window.identifier == toastIdentifier
            || window.identifier == permissionIdentifier
    }

    @MainActor
    static func excludedWindowIDs() -> [CGWindowID] {
        (NSApp?.windows ?? []).filter { $0.isVisible && excludes($0) }.compactMap {
            $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil
        }
    }
}
