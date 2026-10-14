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
            || window.identifier == ScreenRecordingWindowController.identifier
    }

    @MainActor
    static func excludedWindowIDs() -> [CGWindowID] {
        (NSApp?.windows ?? []).filter { $0.isVisible && excludes($0) }.compactMap {
            captureWindowID($0.windowNumber)
        }
    }

    /// AppKit exposes an Int, but Quartz only accepts a nonzero 32-bit ID.
    /// A stale or unrepresentable number must not trap while preparing capture.
    static func captureWindowID(_ number: Int) -> CGWindowID? {
        guard let id = CGWindowID(exactly: number), id != kCGNullWindowID else { return nil }
        return id
    }
}
