import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Screen recording views", .exclusiveUIState)
@MainActor
struct ScreenRecordingVisualTests {
    @Test func `setup and preview render in both appearances`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.options.camera = true
        fixture.model.options.systemAudio = true
        fixture.model.options.microphone = true
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let bitmap = try await ScreenshotSnapshotSupport.bitmap(of:
                ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
                    .environment(\.askGlassMaterialOverride, .opaque).frame(width: 540, height: 740)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                dark: scheme == .dark)
            #expect(bitmap.pixelsWide > 400 && bitmap.pixelsHigh > 400)
            try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage), name: "recording-setup-" + name)
        }
        fixture.model.options.countdown = 0
        fixture.model.start()
        await fixture.model.pendingTask?.value
        let controls = try await ScreenshotSnapshotSupport.bitmap(of:
            ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
                .environment(\.askGlassMaterialOverride, .opaque).frame(width: 460, height: 280)
                .background(Color(nsColor: .windowBackgroundColor)))
        try ScreenshotSnapshotSupport.write(#require(controls.cgImage), name: "recording-controls")
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        let preview = try await ScreenshotSnapshotSupport.bitmap(of:
            ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
                .environment(\.askGlassMaterialOverride, .opaque).frame(width: 680, height: 660)
                .background(Color(nsColor: .windowBackgroundColor)))
        #expect(preview.pixelsWide > 600)
        try ScreenshotSnapshotSupport.write(#require(preview.cgImage), name: "recording-preview")
        await fixture.clean()
    }

    @Test func `recorder windows are excluded and close cleans up`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let presenter = ScreenRecordingWindowController()
        await fixture.setup()
        presenter.show(fixture.model)
        #expect(try ScreenshotCaptureWindowPolicy.excludes(#require(presenter.window)))
        presenter.outline(.region(displayID: 1, rect: CGRect(x: 100, y: 100, width: 200, height: 100)))
        #expect(try ScreenshotCaptureWindowPolicy.excludes(#require(presenter.border)))
        #expect(presenter.border?.ignoresMouseEvents == true)
        presenter.indicator("● 00:01")
        presenter.indicator(nil)
        presenter.outline(nil)
        presenter.requestClose()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .idle)
        presenter.hide()
        await fixture.clean()
    }

    @Test(arguments: InterfaceStyle.allCases, [AppLanguage.english, .simplifiedChinese])
    func `setup shares app surfaces in both styles and languages`(
        style: InterfaceStyle,
        language: AppLanguage
    ) async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(language)
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.options.camera = true
        for dark in [false, true] {
            let bitmap = try await ScreenshotSnapshotSupport.bitmap(of:
                ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
                    .environment(\.interfaceStyle, style).frame(width: 540, height: 740), dark: dark)
            #expect(bitmap.pixelsWide >= 540 && bitmap.pixelsHigh >= 700)
            try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage),
                                                name: "recording-\(style.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")")
        }
        await fixture.clean()
    }

    @Test func `window follows appearance and keeps primary action visible on small screens`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        let settings = SettingsStore(defaults: defaults)
        settings.appearanceMode = .light
        let presenter = ScreenRecordingWindowController(settings: settings)
        await fixture.setup()
        fixture.model.options.camera = true
        presenter.show(fixture.model)
        try await Task.sleep(for: .milliseconds(150))
        let window = try #require(presenter.window)
        #expect(window.appearance?.name == .aqua)
        settings.appearanceMode = .dark
        try await Task.sleep(for: .milliseconds(80))
        #expect(window.appearance?.name == .darkAqua)
        for language in AppLanguage.allCases {
            let previous = AppLocalization.shared.language
            AppLocalization.shared.setLanguage(language)
            defer { AppLocalization.shared.setLanguage(previous) }
            // Start remains outside the scrolling settings, including with camera controls expanded.
            window.setContentSize(CGSize(width: 540, height: 440))
            try await Task.sleep(for: .milliseconds(100))
            let elements = nodes(window)
            let labels = elements.filter {
                value($0, "accessibilityLabel") as? String == L("recording.start") ||
                    value($0, "accessibilityTitle") as? String == L("recording.start")
            }
            let description = elements.compactMap { value($0, "accessibilityLabel") as? String }.joined(separator: ", ")
            let start = try #require(labels.first, "Missing start button for \(language): \(description)")
            let frame = try #require(value(start, "accessibilityFrame") as? NSValue).rectValue
            #expect(frame.width > 0 && frame.height > 0)
            #expect(window.frame.contains(frame), "The start action must stay inside the window")
        }
        presenter.requestClose()
        await fixture.model.pendingTask?.value
        presenter.hide()
        await fixture.clean()
    }

    @Test func `window size fits available screen height`() {
        for state in [ScreenRecordingCoordinator.State.setup, .preview, .recording, .countdown] {
            let size = ScreenRecordingWindowController.contentSize(
                for: state,
                available: CGSize(width: 600, height: 480)
            )
            #expect(size.width <= 600 && size.height <= 480)
        }
    }

    @Test func `native recording window review screenshots`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RECORDING_WINDOW_SNAPSHOTS"] else { return }
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        let settings = SettingsStore(defaults: defaults)
        let presenter = ScreenRecordingWindowController(settings: settings)
        await fixture.setup()
        fixture.model.options.camera = true
        fixture.model.options.systemAudio = true
        fixture.model.options.microphone = true
        presenter.show(fixture.model)
        let window = try #require(presenter.window)
        for style in InterfaceStyle.allCases {
            settings.interfaceStyle = style
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                try await capture(
                    window,
                    directory: directory,
                    name: "recording-window-\(style.rawValue)-\(dark ? "dark" : "light")"
                )
            }
        }
        settings.interfaceStyle = .liquidGlass
        fixture.model.options.countdown = 0
        fixture.model.start()
        await fixture.model.pendingTask?.value
        try await capture(window, directory: directory, name: "recording-window-controls")
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        fixture.model.seek(0.4)
        try await capture(window, directory: directory, name: "recording-window-preview")
        fixture.model.cancel()
        await fixture.model.pendingTask?.value
        presenter.hide()
        await fixture.clean()
    }

    private func capture(_ window: NSWindow, directory: String, name: String) async throws {
        try await Task.sleep(for: .seconds(1))
        // Keep glass captures free of real desktop content.
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -100, dy: -100), styleMask: .borderless,
                                backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.backgroundColor = NSColor(calibratedWhite:
            window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.12 : 0.96, alpha: 1)
        backdrop.order(.below, relativeTo: window.windowNumber)
        defer { backdrop.orderOut(nil); backdrop.close() }
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        // Let the window server receive the new layer tree after a theme change.
        // Waiting synchronously for screencapture can freeze that commit.
        try await Task.sleep(for: .seconds(1))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                          URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
    }

    private func value(_ node: NSObject, _ key: String) -> Any? {
        node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
    }

    private func nodes(_ node: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            (value(object, "accessibilityChildren") as? [NSObject] ?? []).forEach(visit)
            if let view = object as? NSView {
                view.subviews.forEach(visit)
            }
        }
        visit(node)
        if let window = node as? NSWindow, let content = window.contentView {
            visit(content)
        }
        return result
    }
}
