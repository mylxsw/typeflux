import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingUIInteractionTests {
    @Test func `preview actions share control metrics and stay reachable in narrow windows`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let previous = AppLocalization.shared.language
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            AppLocalization.shared.setLanguage(previous)
        }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        fixture.model.outputDirectory = fixture.root.appendingPathComponent(String(repeating: "Long folder ", count: 8))
        var directories = 0, saveAs = 0, discards = 0
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for format in ScreenRecordingFormat.allCases {
                fixture.model.options.format = format
                try await SettingsBehaviorTestSupport.withWindow(
                    ScreenRecordingPreviewView(model: fixture.model, close: { discards += 1 },
                                               chooseDirectory: { directories += 1 }, saveAs: { saveAs += 1 }),
                    width: 760, height: 632
                ) { window, content in
                    let nodes = SettingsBehaviorTestSupport.elements(in: content)
                    var previousFrame: CGRect?
                    for action in ["directory", "copy", "saveAs", "save"] {
                        let button = try #require(nodes.first {
                            $0.value("accessibilityIdentifier") as? String == "recording.preview." + action
                        })
                        #expect(button.frame.height == SettingsControlMetrics.height)
                        #expect(window.frame.contains(button.frame))
                        #expect(button.value("isAccessibilityEnabled") as? Bool == true)
                        if let previousFrame {
                            #expect(button.frame.minX >= previousFrame.maxX + 7)
                            #expect(button.frame.minY == previousFrame.minY)
                        }
                        previousFrame = button.frame
                        if action == "directory" || action == "saveAs" {
                            try button.press()
                        }
                    }
                    let discard = try #require(nodes.first {
                        $0.value("accessibilityIdentifier") as? String == "recording.preview.discard"
                    })
                    #expect(discard.frame.height == SettingsControlMetrics.height)
                    try discard.press()
                }
            }
        }
        #expect(directories == 4 && saveAs == 4 && discards == 4)
        fixture.model.options.format = .gif
        fixture.model.trimEnd = 0
        try await SettingsBehaviorTestSupport
            .withWindow(ScreenRecordingPreviewView(model: fixture.model)) { _, content in
                for action in ["copy", "saveAs", "save"] {
                    let button = try #require(SettingsBehaviorTestSupport.elements(in: content).first {
                        $0.value("accessibilityIdentifier") as? String == "recording.preview." + action
                    })
                    #expect(button.value("isAccessibilityEnabled") as? Bool == false)
                }
            }
        await fixture.clean()
    }

    @Test func `screenshot toolbar exposes recording without opening More`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        var actions = 0
        for editable in [true, false] {
            var state = ScreenshotEditorToolbarModel.State()
            state.canScrollCapture = editable
            try await SettingsBehaviorTestSupport.withWindow(
                ScreenshotEditorToolbar(state: state) {
                    if case .record = $0 {
                        actions += 1
                    }
                },
                width: 1200, height: 120
            ) { window, content in
                let button = try #require(SettingsBehaviorTestSupport.elements(in: content).first {
                    $0.value("accessibilityIdentifier") as? String == "screenshot.record"
                })
                let pin = try #require(SettingsBehaviorTestSupport.elements(in: content).first {
                    $0.value("accessibilityIdentifier") as? String == "screenshot.pin"
                })
                #expect(button.frame.size == CGSize(width: 30, height: 30))
                #expect(button.frame.size == pin.frame.size)
                #expect(button.frame.minY == pin.frame.minY)
                #expect(pin.frame.minX - button.frame.maxX == 2)
                #expect(button.label == L("recording.title"))
                #expect(window.frame.contains(button.frame))
                #expect(button.value("isAccessibilityEnabled") as? Bool == editable)
                if editable {
                    try button.press()
                }
            }
        }
        #expect(actions == 1)
        var state = ScreenshotEditorToolbarModel.State()
        state.showsScrollCapture = false
        try await SettingsBehaviorTestSupport.withWindow(ScreenshotEditorToolbar(state: state) { _ in }) { _, content in
            #expect(!SettingsBehaviorTestSupport.elements(in: content).contains {
                $0.value("accessibilityIdentifier") as? String == "screenshot.record"
            })
        }
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        for dark in [true, false] {
            let image = try await ScreenshotSnapshotSupport.toolbar(.init(), dark: dark)
            try ScreenshotSnapshotSupport.write(#require(image.cgImage),
                                                name: dark ? "screenshot-recording-entry" :
                                                    "screenshot-recording-entry-light")
        }
    }

    @Test func `native selection toolbar remains visible through refresh and language changes`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let previous = AppLocalization.shared.language
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            AppLocalization.shared.setLanguage(previous)
        }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        defer { presenter.hide() }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            try await Task.sleep(for: .milliseconds(150))
            presenter.syncChrome()
            let window = try #require(presenter.window)
            let content = try #require(window.contentView)
            #expect(window.isVisible)
            #expect(window.frame.width > 500 && window.frame.height > 40)
            #expect(try #require(presenter.activeScreen).visibleFrame.contains(window.frame))
            #expect(content.fittingSize.width > 500 && content.fittingSize.height > 40)
            #expect(presenter.selectionPanels.allSatisfy { $0.level < window.level })
            let start = try #require(SettingsBehaviorTestSupport.elements(in: content).first {
                $0.value("accessibilityIdentifier") as? String == "recording.start"
            })
            #expect(start.frame.width > 30 && start.frame.height > 20)
            #expect(window.frame.contains(start.frame))
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try ScreenshotSnapshotSupport.write(
                #require(bitmap.cgImage),
                name: "recording-native-toolbar-\(language.rawValue)"
            )
        }
        // A transient unmeasurable host must not collapse a usable panel.
        let window = try #require(presenter.window)
        let content = window.contentView
        let frame = window.frame
        window.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        presenter.syncChrome()
        #expect(window.frame == frame)
        window.contentView = content
        // A toolbar dragged off screen must remain reachable after the next refresh.
        window.setFrameOrigin(CGPoint(x: -20000, y: 20000))
        presenter.syncChrome()
        #expect(try #require(presenter.activeScreen).visibleFrame.contains(window.frame))
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    @Test func `toolbar buttons drive source format devices and capture controls`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        try await Task.sleep(for: .milliseconds(150))
        try press(L("recording.source.window"), in: #require(presenter.window))
        #expect(fixture.model.sourceKind == .window)
        try press(L("recording.source.region"), in: #require(presenter.window))
        #expect(fixture.model.sourceKind == .region)
        try press(L("recording.source.display"), in: #require(presenter.window))
        try press("GIF", in: #require(presenter.window))
        #expect(fixture.model.options.format == .gif)
        try press("MP4", in: #require(presenter.window))
        try press(L("recording.systemAudio"), in: #require(presenter.window))
        #expect(fixture.model.options.systemAudio)
        try press(L("recording.microphone"), in: #require(presenter.window))
        try press(L("recording.camera"), in: #require(presenter.window))
        #expect(fixture.model.options.microphone && fixture.model.options.camera)
        try await Task.sleep(for: .milliseconds(80))
        #expect(presenter.cameraPanel != nil)
        try press(L("recording.camera"), in: #require(presenter.window))
        #expect(!fixture.model.options.camera)
        fixture.model.options.countdown = 0
        try press(L("recording.start"), in: #require(presenter.window))
        await fixture.model.pendingTask?.value
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.model.state == .recording)
        try press(L("recording.pause"), in: #require(presenter.window))
        #expect(fixture.model.state == .paused)
        try press(L("recording.resume"), in: #require(presenter.window))
        #expect(fixture.model.state == .recording)
        try press(L("recording.stop"), in: #require(presenter.window))
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .preview)
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    @Test func `permission omission returns to a usable toolbar`() async throws {
        let fixture = ScreenRecordingCoordinatorTests
            .Fixture(authorize: { _ in throw ScreenRecordingFailure.microphonePermission })
        await fixture.setup()
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        fixture.model.setDevice(.audio, enabled: true)
        try await Task.sleep(for: .milliseconds(180))
        #expect(!fixture.model.canStart)
        fixture.model.setDevice(.audio, enabled: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.model.canStart)
        presenter.requestClose()
        await fixture.model.pendingTask?.value
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    @Test func `saved and recovery toasts keep owned windows and file actions`() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        let source = try #require(fixture.model.sourceURL)
        let toast = ScreenRecordingToastController()
        toast.showRecovery(source, open: {}, discard: {})
        let panel = try #require(toast.panel)
        #expect(ScreenshotCaptureWindowPolicy.excludes(panel))
        #expect(panel.isVisible)
        toast.hide()
        toast.showSaved(source, thumbnail: ScreenshotSnapshotSupport.sampleScreen(), duration: 1.2)
        try await Task.sleep(for: .milliseconds(120))
        try press(L("recording.copy"), in: #require(toast.panel))
        #expect(NSPasteboard.general.readObjects(forClasses: [NSURL.self])?.first as? URL == source)
        toast.hide()
        #expect(toast.panel == nil)
        await fixture.clean()
    }

    @Test func `export progress and state wrappers render the live components`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        _ = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingView(
            model: fixture.model,
            close: {},
            chooseDirectory: {}
        ))
        await fixture.recording()
        _ = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingView(
            model: fixture.model,
            close: {},
            chooseDirectory: {}
        ))
        fixture.model.stop(); await fixture.model.pendingTask?.value
        _ = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingView(
            model: fixture.model,
            close: {},
            chooseDirectory: {}
        ).frame(width: 920, height: 632))
        let progress = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingExportProgress(
            progress: 0.35,
            format: .mp4
        ).frame(width: 230, height: 30).padding(12))
        try ScreenshotSnapshotSupport.write(#require(progress.cgImage), name: "recording-export-progress")
        await fixture.clean()
    }

    private func press(_ title: String, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let nodes = SettingsBehaviorTestSupport.elements(in: content)
        let button = try #require(nodes.first { node in
            (node.label == title || node.value("accessibilityTitle") as? String == title) &&
                node.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }, "Missing button: \(title)")
        #expect(window.isVisible && window.frame.width > 0 && window.frame.height > 0)
        #expect(button.frame.width > 0 && button.frame.height > 0)
        #expect(window.frame.contains(button.frame), "The button must be inside the visible native panel")
        try button.press()
    }
}
