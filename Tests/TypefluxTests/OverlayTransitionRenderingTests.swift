import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized)
struct OverlayTransitionRenderingTests {
    @Test(arguments: OverlayStyle.allCases) @MainActor
    func recordingHintsKeepTheirRoundedEndsInsideTheWindow(style: OverlayStyle) async throws {
        let application = NSApplication.shared
        let previousWindows = Set(application.windows.map(\.windowNumber))
        let suiteName = "OverlayHintRenderingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let controller = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismissImmediately() }
        controller.showLockedRecording()
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        let hints = [
            "本次请求将使用结构化处理专家人设进行处理",
            "This request will use the structured writing expert persona to organize the response clearly."
        ]
        for (index, hint) in hints.enumerated() {
            controller.showLockedRecording(hintText: hint)
            try await Task.sleep(for: .milliseconds(450))
            let bitmap = try capture(window, name: "hint-\(style.rawValue)-\(index)")
            let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
            // Sample only the hint above the lower recording capsule.
            let hintBottom = bitmap.pixelsHigh - Int(87 * scale)
            var left = bitmap.pixelsWide
            var right = -1
            var top = bitmap.pixelsHigh
            var bottom = -1
            for y in 0 ..< hintBottom {
                for x in 0 ..< bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
            #expect(right > left)
            #expect(CGFloat(left) >= 30 * scale)
            #expect(CGFloat(bitmap.pixelsWide - right - 1) >= 30 * scale)
            #expect(CGFloat(top) >= 20 * scale)
            if style == .classic, right > left, bottom > top {
                let corner = try #require(bitmap.colorAt(x: left + 2, y: top + 2))
                let center = try #require(bitmap.colorAt(x: (left + right) / 2, y: (top + bottom) / 2))
                #expect(corner.alphaComponent < 0.1)
                #expect(center.alphaComponent > 0.9)
            }
        }
    }

    @Test(arguments: OverlayStyle.allCases) @MainActor
    func captionsRenderIntermediateSizesInBothDirections(style: OverlayStyle) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let application = NSApplication.shared
        let previousWindows = Set(application.windows.map(\.windowNumber))
        let suiteName = "OverlayTransitionRenderingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let controller = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismissImmediately() }
        controller.show()
        controller.updateLevel(0.5)
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        try await Task.sleep(for: .milliseconds(60))
        let appearing = try capture(window, name: "00-appearing")
        try await Task.sleep(for: .milliseconds(340))
        let compact = try capture(window, name: "01-compact")
        #expect(appearing.peakAlpha > 0.02)
        #expect(appearing.peakAlpha < compact.peakAlpha - 0.02)

        controller.updateRecordingPreviewText("The caption keeps its line breaks while the capsule opens and closes.")
        try await Task.sleep(for: .milliseconds(80))
        let expanding = try capture(window, name: "02-expanding")
        try await Task.sleep(for: .milliseconds(350))
        let expanded = try capture(window, name: "03-expanded")
        if style == .classic {
            #expect(expanding.opaqueWidth > compact.opaqueWidth + 12)
            #expect(expanding.opaqueWidth < expanded.opaqueWidth - 12)
        }

        controller.updateRecordingPreviewText("")
        try await Task.sleep(for: .milliseconds(80))
        let collapsing = try capture(window, name: "04-collapsing")
        try await Task.sleep(for: .milliseconds(350))
        let collapsed = try capture(window, name: "05-collapsed")
        if style == .classic {
            #expect(collapsing.opaqueWidth > collapsed.opaqueWidth + 12)
            #expect(collapsing.opaqueWidth < expanded.opaqueWidth - 12)
            #expect(abs(collapsed.opaqueWidth - compact.opaqueWidth) <= 2)
        }

        let compactCenter = try #require(compact.waveformCenter)
        let bottomOffset = CGFloat(compact.pixelsHigh) - compactCenter.y
        for bitmap in [expanding, expanded, collapsing, collapsed] {
            let center = try #require(bitmap.waveformCenter)
            #expect(abs(center.x - CGFloat(bitmap.pixelsWide) / 2) <= 2)
            #expect(abs(CGFloat(bitmap.pixelsHigh) - center.y - bottomOffset) <= 2)
        }

        controller.updateRecordingPreviewText("Caption before processing")
        try await Task.sleep(for: .milliseconds(400))
        controller.showProcessing()
        try await Task.sleep(for: .milliseconds(80))
        let processingTransition = try capture(window, name: "06-processing-transition")
        try await Task.sleep(for: .milliseconds(350))
        let processing = try capture(window, name: "07-processing")
        if style == .classic {
            #expect(processingTransition.opaqueWidth > processing.opaqueWidth + 12)
            #expect(processingTransition.opaqueWidth < expanded.opaqueWidth - 12)
        }
        controller.transitionToLLMPhase()
        try await Task.sleep(for: .milliseconds(150))
        let thinking = try capture(window, name: "08-thinking")
        #expect(thinking.totalBrightness > processing.totalBrightness)

        let processingFrame = window.frame
        controller.updateStreamingText("A streaming processing caption uses the same capsule.")
        try await Task.sleep(for: .milliseconds(80))
        let streamingExpansion = try capture(window, name: "09-streaming-expansion")
        try await Task.sleep(for: .milliseconds(350))
        let streaming = try capture(window, name: "10-streaming")
        if style == .classic {
            #expect(streamingExpansion.opaqueWidth > processing.opaqueWidth + 12)
            #expect(streamingExpansion.opaqueWidth < streaming.opaqueWidth - 12)
        }
        controller.updateStreamingText("")
        try await Task.sleep(for: .milliseconds(80))
        let streamingCollapse = try capture(window, name: "11-streaming-collapse")
        try await Task.sleep(for: .milliseconds(350))
        if style == .classic {
            #expect(streamingCollapse.opaqueWidth > processing.opaqueWidth + 12)
            #expect(streamingCollapse.opaqueWidth < streaming.opaqueWidth - 12)
        }
        #expect(window.frame == processingFrame)

        controller.dismiss(after: 0)
        try await Task.sleep(for: .milliseconds(70))
        let disappearing = try capture(window, name: "12-disappearing")
        #expect(disappearing.peakAlpha > 0.02)
        #expect(disappearing.peakAlpha < collapsed.peakAlpha - 0.02)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!window.isVisible)
    }

    @MainActor
    private func capture(_ window: NSWindow, name: String) throws -> NSBitmapImageRep {
        let view = try #require(window.contentView)
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_OVERLAY_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }
}

private extension NSBitmapImageRep {
    var totalBrightness: CGFloat {
        var sum: CGFloat = 0
        for y in stride(from: 0, to: pixelsHigh, by: 2) {
            for x in stride(from: 0, to: pixelsWide, by: 2) {
                if let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    sum += (color.redComponent + color.greenComponent + color.blueComponent) * color.alphaComponent
                }
            }
        }
        return sum
    }

    var peakAlpha: CGFloat {
        var peak: CGFloat = 0
        for y in stride(from: 0, to: pixelsHigh, by: 4) {
            for x in stride(from: 0, to: pixelsWide, by: 4) {
                peak = max(peak, colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return peak
    }

    var waveformCenter: CGPoint? {
        var minX = pixelsWide
        var maxX = -1
        var minY = pixelsHigh
        var maxY = -1
        for y in max(0, pixelsHigh - 150) ..< max(0, pixelsHigh - 80) {
            for x in 0 ..< pixelsWide {
                guard let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5, color.redComponent > 0.8,
                      color.greenComponent > 0.8, color.blueComponent > 0.8 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)
    }

    var opaqueWidth: Int {
        var minX = pixelsWide
        var maxX = -1
        for y in stride(from: 0, to: pixelsHigh, by: 2) {
            for x in 0 ..< pixelsWide {
                if let color = colorAt(x: x, y: y), color.alphaComponent > 0.9 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return max(0, maxX - minX + 1)
    }
}
