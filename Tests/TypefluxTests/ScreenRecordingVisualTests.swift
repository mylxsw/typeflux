import AppKit
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
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme), dark: scheme == .dark)
            #expect(bitmap.pixelsWide > 400 && bitmap.pixelsHigh > 400)
            try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage), name: "recording-setup-" + name)
        }
        fixture.model.options.countdown = 0
        fixture.model.start()
        await fixture.model.pendingTask?.value
        let controls = try await ScreenshotSnapshotSupport.bitmap(of:
            ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
                .background(Color(nsColor: .windowBackgroundColor)))
        try ScreenshotSnapshotSupport.write(#require(controls.cgImage), name: "recording-controls")
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        let preview = try await ScreenshotSnapshotSupport.bitmap(of:
            ScreenRecordingView(model: fixture.model, close: {}, chooseDirectory: {})
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
}
