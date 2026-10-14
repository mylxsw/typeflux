import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingUIInteractionTests {
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
        try button.press()
    }
}
