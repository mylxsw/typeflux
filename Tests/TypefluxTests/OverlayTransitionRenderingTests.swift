import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
struct OverlayTransitionRenderingTests {
    @Test(arguments: OverlayStyle.allCases) @MainActor
    func noticesAndFailuresFitTheirContentAfterCapsuleTransitions(style: OverlayStyle) async throws {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let suiteName = "OverlaySharedLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let controller = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismissImmediately() }
        controller.showLockedRecording()
        let window = try #require(NSApplication.shared.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        try await settle(1)
        let recordingFrame = window.frame
        controller.showNotice(message: "Copied to clipboard")
        let shortHeight = try await settledFrame(of: window, changingFrom: recordingFrame).height
        #expect(window.frame.width == 344)
        #expect(shortHeight >= 55 && shortHeight < 90)
        _ = try capture(window, name: "notice-short-\(style.rawValue)")
        let before1 = window.frame
        controller.showNotice(message: String(repeating: "A notice can contain several lines of text. ", count: 20))
        _ = try await settledFrame(of: window, changingFrom: before1)
        #expect(window.frame.height > shortHeight)
        #expect(window.frame.height < 125)
        _ = try capture(window, name: "notice-long-\(style.rawValue)")
        let before2 = window.frame
        controller.showPassiveNotice(message: "Copied")
        _ = try await settledFrame(of: window, changingFrom: before2)
        #expect(window.frame.height <= shortHeight)
        #expect(window.ignoresMouseEvents)
        let before3 = window.frame
        controller.showFailure(message: "Please try again.")
        _ = try await settledFrame(of: window, changingFrom: before3)
        let failureHeight = window.frame.height
        #expect(window.frame.width == 372)
        #expect(failureHeight < 180)
        _ = try capture(window, name: "failure-short-\(style.rawValue)")
        let before4 = window.frame
        controller.showRetryableFailure(message: String(repeating: "A detailed failure remains scrollable.\n", count: 30))
        _ = try await settledFrame(of: window, changingFrom: before4)
        #expect(window.frame.height > failureHeight)
        #expect(window.frame.height < 320)
        _ = try capture(window, name: "failure-long-\(style.rawValue)")
        let before5 = window.frame
        controller.showNotice(message: "Copied to clipboard")
        _ = try await settledFrame(of: window, changingFrom: before5)
        #expect(window.frame.height == shortHeight)
    }

    @Test(arguments: OverlayStyle.allCases) @MainActor
    func resultDialogFitsShortTextAndCapsLongTextAfterRecording(style: OverlayStyle) async throws {
        let application = NSApplication.shared
        let previousWindows = Set(application.windows.map(\.windowNumber))
        let suiteName = "OverlayResultLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let controller = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismissImmediately() }
        controller.showLockedRecording()
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        controller.updateRecordingPreviewText("A recording caption before the result dialog.")
        try await settle(1)
        let captionFrame = window.frame
        controller.showResultDialog(title: "Copy result", message: "Explain how these topics were chosen and describe the complete process.")
        _ = try await settledFrame(of: window, changingFrom: captionFrame)
        let shortHeight = window.frame.height
        #expect(window.frame.width == 446)
        #expect(shortHeight > 100)
        #expect(shortHeight < 170)
        let short = try capture(window, name: "result-short-\(style.rawValue)")
        let scale = CGFloat(short.pixelsWide) / window.frame.width
        var firstTextRow = short.pixelsHigh
        for y in 0 ..< short.pixelsHigh {
            for x in stride(from: 0, to: short.pixelsWide, by: 2) {
                if let color = short.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.greenComponent > 0.7, color.blueComponent > 0.7 {
                    firstTextRow = min(firstTextRow, y)
                }
            }
        }
        #expect(CGFloat(firstTextRow) / scale >= 10)
        #expect(CGFloat(firstTextRow) / scale < 25)

        let before6 = window.frame
        controller.showResultDialog(title: "Copy result", message: String(repeating: "A long result remains available for scrolling and copying.\n", count: 30))
        _ = try await settledFrame(of: window, changingFrom: before6)
        #expect(window.frame.height > shortHeight + 40)
        #expect(window.frame.height <= 240)
        _ = try capture(window, name: "result-long-\(style.rawValue)")
        let before7 = window.frame
        controller.showResultDialog(title: "Copy result", message: "A short result again.")
        _ = try await settledFrame(of: window, changingFrom: before7)
        #expect(window.frame.height <= shortHeight)
    }

    @Test @MainActor
    func recordingHintStaysCenteredAndFollowsTheCapsuleDuringMorphing() async throws {
        let application = NSApplication.shared
        let previousWindows = Set(application.windows.map(\.windowNumber))
        let suiteName = "OverlayHintMotionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OverlayStyle.classic.rawValue, forKey: "ui.overlayStyle")
        let controller = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismissImmediately() }
        controller.showLockedRecording(hintText: "Using the structured writing expert persona")
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        let metering = Task { @MainActor in
            var frame = 0
            while !Task.isCancelled {
                controller.updateLevel(Float(frame % 8) / 10)
                frame += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        defer { metering.cancel() }
        try await Task.sleep(for: .milliseconds(450))
        for (transition, caption) in ["A caption expands beneath the recording hint.", ""].enumerated() {
            controller.updateRecordingPreviewText(caption)
            for frame in 0 ..< 12 {
                try await Task.sleep(for: .milliseconds(25))
                let bitmap = try capture(window, name: "hint-motion-\(transition)-\(frame)")
                let bands = bitmap.opaqueHorizontalBands
                let hint = try #require(bands.first)
                let capsule = try #require(bands.last)
                let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
                #expect(bands.count == 2)
                #expect(abs(hint.midX - CGFloat(bitmap.pixelsWide) / 2) <= scale)
                #expect(abs(hint.midX - capsule.midX) <= scale)
                #expect(abs(capsule.minY - hint.maxY - 10 * scale) <= 2 * scale)
            }
        }
    }

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
        // Motion runs several times slower than in production and every intermediate frame is
        // found by polling for it, so the assertions do not depend on wall-clock timing.
        let motionScale = 4.0
        controller.motionScale = motionScale
        defer { controller.dismissImmediately() }
        controller.show()
        controller.updateLevel(0.5)
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        let appearing = try await captureFirst(window, name: "00-appearing") { $0.peakAlpha > 0.02 }
        try await settle(motionScale)
        let compact = try capture(window, name: "01-compact")
        #expect(appearing.peakAlpha > 0.02)
        #expect(appearing.peakAlpha < compact.peakAlpha - 0.02)

        controller.updateRecordingPreviewText("The caption keeps its line breaks while the capsule opens and closes.")
        let expanding = style == .classic
            ? try await captureFirst(window, name: "02-expanding") { $0.opaqueWidth > compact.opaqueWidth + 12 }
            : nil
        try await settle(motionScale)
        let expanded = try capture(window, name: "03-expanded")
        if let expanding {
            #expect(expanding.opaqueWidth > compact.opaqueWidth + 12)
            #expect(expanding.opaqueWidth < expanded.opaqueWidth - 12)
            let scale = CGFloat(expanding.pixelsWide) / window.frame.width
            if CGFloat(expanding.opaqueWidth) < 330 * scale {
                #expect(expanding.captionBrightness(scale: scale) < 0.02)
            }
        }

        controller.updateRecordingPreviewText("")
        let collapsing = style == .classic
            ? try await captureFirst(window, name: "04-collapsing") { $0.opaqueWidth < expanded.opaqueWidth - 12 }
            : nil
        try await settle(motionScale)
        let collapsed = try capture(window, name: "05-collapsed")
        if let collapsing {
            #expect(collapsing.opaqueWidth > collapsed.opaqueWidth + 12)
            #expect(collapsing.opaqueWidth < expanded.opaqueWidth - 12)
            #expect(abs(collapsed.opaqueWidth - compact.opaqueWidth) <= 2)
            let scale = CGFloat(collapsing.pixelsWide) / expanded.size.width
            if CGFloat(collapsing.opaqueWidth) < 330 * scale {
                #expect(collapsing.captionBrightness(scale: scale) < 0.02)
            }
        }

        let compactCenter = try #require(compact.waveformCenter)
        let bottomOffset = CGFloat(compact.pixelsHigh) - compactCenter.y
        for bitmap in [expanding, expanded, collapsing, collapsed].compactMap({ $0 }) {
            let center = try #require(bitmap.waveformCenter)
            #expect(abs(center.x - CGFloat(bitmap.pixelsWide) / 2) <= 2)
            #expect(abs(CGFloat(bitmap.pixelsHigh) - center.y - bottomOffset) <= 2)
        }

        controller.updateRecordingPreviewText("Caption before processing")
        try await settle(motionScale)
        let captioned = try capture(window, name: "05b-captioned")
        controller.showProcessing()
        let processingTransition = style == .classic
            ? try await captureFirst(window, name: "06-processing-transition") { $0.opaqueWidth < captioned.opaqueWidth - 12 }
            : nil
        try await settle(motionScale)
        let processing = try capture(window, name: "07-processing")
        if let processingTransition {
            #expect(processingTransition.opaqueWidth > processing.opaqueWidth + 12)
            #expect(processingTransition.opaqueWidth < expanded.opaqueWidth - 12)
        }
        controller.transitionToLLMPhase()
        // Recognition progress has nearly reached the LLM phase's starting point by now, so the
        // fill only becomes visibly brighter once the content phase has advanced past it.
        _ = try await captureFirst(window, name: "08-thinking") { $0.totalBrightness > processing.totalBrightness }

        let processingFrame = window.frame
        controller.updateStreamingText("A streaming processing caption uses the same capsule.")
        let streamingExpansion = style == .classic
            ? try await captureFirst(window, name: "09-streaming-expansion") { $0.opaqueWidth > processing.opaqueWidth + 12 }
            : nil
        try await settle(motionScale)
        let streaming = try capture(window, name: "10-streaming")
        if let streamingExpansion {
            #expect(streamingExpansion.opaqueWidth > processing.opaqueWidth + 12)
            #expect(streamingExpansion.opaqueWidth < streaming.opaqueWidth - 12)
        }
        controller.updateStreamingText("")
        let streamingCollapse = style == .classic
            ? try await captureFirst(window, name: "11-streaming-collapse") { $0.opaqueWidth < streaming.opaqueWidth - 12 }
            : nil
        try await settle(motionScale)
        if let streamingCollapse {
            #expect(streamingCollapse.opaqueWidth > processing.opaqueWidth + 12)
            #expect(streamingCollapse.opaqueWidth < streaming.opaqueWidth - 12)
        }
        #expect(window.frame == processingFrame)

        controller.dismiss(after: 0)
        let disappearing = try await captureFirst(window, name: "12-disappearing") {
            $0.peakAlpha < collapsed.peakAlpha - 0.02
        }
        #expect(disappearing.peakAlpha > 0.02)
        #expect(disappearing.peakAlpha < collapsed.peakAlpha - 0.02)
        try await settle(motionScale)
        #expect(!window.isVisible)
    }

    /// Waits past a motion's morph and its follow-up window geometry cleanup. The cleanup is
    /// scheduled before this sleep starts and fires on the same queue, so it always runs first.
    @MainActor
    private func settle(_ motionScale: Double) async throws {
        let delay = OverlayMotion.geometrySettleDelay(scale: motionScale) + 0.15
        try await Task.sleep(for: .seconds(delay))
    }

    /// Waits for a window animation to start moving away from `previous` and come to rest.
    @MainActor
    private func settledFrame(of window: NSWindow, changingFrom previous: NSRect, timeout: TimeInterval = 5) async throws -> NSRect {
        let deadline = Date().addingTimeInterval(timeout)
        var last = window.frame
        var stableSamples = 0
        while stableSamples < 4 {
            try #require(Date() < deadline, "The window frame never settled")
            try await Task.sleep(for: .milliseconds(25))
            let frame = window.frame
            stableSamples = frame == last && frame != previous ? stableSamples + 1 : 0
            last = frame
        }
        return last
    }

    /// Polls until a frame satisfies `isReached` and returns it, failing if it never does.
    @MainActor
    private func captureFirst(
        _ window: NSWindow,
        name: String,
        timeout: TimeInterval = 5,
        until isReached: (NSBitmapImageRep) -> Bool
    ) async throws -> NSBitmapImageRep {
        let deadline = Date().addingTimeInterval(timeout)
        var bitmap = try capture(window, name: name)
        while !isReached(bitmap) {
            try #require(Date() < deadline, "No frame matching \(name) was rendered")
            try await Task.sleep(for: .milliseconds(5))
            bitmap = try capture(window, name: name)
        }
        return bitmap
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
    func captionBrightness(scale: CGFloat) -> CGFloat {
        var brightest: CGFloat = 0
        for y in stride(from: 0, to: max(0, pixelsHigh - Int(87 * scale)), by: 2) {
            for x in stride(from: 0, to: pixelsWide, by: 2) {
                if let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    brightest = max(brightest, color.redComponent * color.alphaComponent)
                }
            }
        }
        return brightest
    }

    var opaqueHorizontalBands: [CGRect] {
        guard bitsPerSample == 8, samplesPerPixel == 4, let data = bitmapData else { return [] }
        let alphaOffset = bitmapFormat.contains(.alphaFirst) ? 0 : 3
        var bands: [CGRect] = []
        var current: CGRect?
        for y in 0 ..< pixelsHigh {
            var left = pixelsWide
            var right = -1
            for x in 0 ..< pixelsWide where data[y * bytesPerRow + x * 4 + alphaOffset] > 230 {
                left = min(left, x)
                right = max(right, x)
            }
            if right > left {
                let row = CGRect(x: left, y: y, width: right - left + 1, height: 1)
                current = current.map { $0.union(row) } ?? row
            } else if let completed = current {
                bands.append(completed)
                current = nil
            }
        }
        if let current { bands.append(current) }
        return bands
    }

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
        let scale = CGFloat(pixelsWide) / size.width
        for y in max(0, pixelsHigh - Int(75 * scale)) ..< max(0, pixelsHigh - Int(40 * scale)) {
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
