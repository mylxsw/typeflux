import AppKit
import Testing
@testable import Typeflux

extension AskLibraryWindowSnapshotTests {
    func captureAndCheckProminentFill(in window: NSWindow, action: String, snapshot: String) async throws {
        // Activation is asynchronous. A prominent control may be neutral until its window is active and key.
        NSApp.activate(ignoringOtherApps: true)
        defer {
            print("\(snapshot): window=\(window.windowNumber), isKeyWindow=\(window.isKeyWindow), "
                + "isActive=\(NSApp.isActive)")
        }
        try await SettingsBehaviorTestSupport.wait("\(snapshot): active application") {
            NSApp.isActive
        }
        window.makeKeyAndOrderFront(nil)
        try await SettingsBehaviorTestSupport.wait("\(snapshot): active application and key library window") {
            NSApp.isActive && window.isKeyWindow
        }
        // The shared capture helper allows another 400 ms for rendering before reading WindowServer pixels.
        try await AskLibraryTestSupport.capture(window, name: snapshot)
        try #require(NSApp.isActive && window.isKeyWindow,
                     "\(snapshot): activation was lost during capture; prominent fill requires an active key window")
        try checkProminentFill(in: window, action: action, snapshot: snapshot)
    }

    /// Inspect the real WindowServer capture: AX presence alone cannot detect a grey primary button.
    private func checkProminentFill(in window: NSWindow, action: String, snapshot: String) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_LIBRARY_SNAPSHOTS"])
        let file = URL(fileURLWithPath: directory).appendingPathComponent(snapshot + ".png")
        let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
        let accent = try #require(NSColor.controlAccentColor.usingColorSpace(.deviceRGB))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Graphite is intentionally neutral, so a colour probe cannot distinguish its prominent fill.
        guard saturation > 0.1 else { return }
        let frame = try AskLibraryTestSupport.action(action, in: window).frame
        let windowFrame = window.frame
        try #require(windowFrame.width > 0 && windowFrame.height > 0 && frame.width > 0 && frame.height > 0)
        let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
        let left = max(0, Int(((frame.minX - windowFrame.minX) * scaleX).rounded(.down)))
        let right = min(bitmap.pixelsWide, Int(((frame.maxX - windowFrame.minX) * scaleX).rounded(.up)))
        let top = max(0, Int(((windowFrame.maxY - frame.maxY) * scaleY).rounded(.down)))
        let bottom = min(bitmap.pixelsHigh, Int(((windowFrame.maxY - frame.minY) * scaleY).rounded(.up)))
        try #require(left < right && top < bottom)
        var tinted = 0
        for y in top ..< bottom {
            for x in left ..< right {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var pixelHue: CGFloat = 0, pixelSaturation: CGFloat = 0
                var pixelBrightness: CGFloat = 0, pixelAlpha: CGFloat = 0
                color.getHue(&pixelHue, saturation: &pixelSaturation,
                             brightness: &pixelBrightness, alpha: &pixelAlpha)
                let difference = abs(pixelHue - hue)
                let hueDistance = min(difference, 1 - difference)
                if hueDistance < 0.1, pixelSaturation > saturation / 2, pixelBrightness > 0.2, pixelAlpha > 0.5 {
                    tinted += 1
                }
            }
        }
        let fraction = Double(tinted) / Double((right - left) * (bottom - top))
        #expect(fraction >= 0.25, "\(snapshot): the New button must have an accent fill, not just an accent glyph")
    }
}
