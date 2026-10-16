import AppKit
import AVFoundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingNativeCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"))
    func `native catalog and region recording exclude owned controls`() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let displayID = try #require((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value)
        let frame = CGRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.midY - 90, width: 240, height: 180)
        let page = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false; page.title = "Typeflux recording fixture"; page.backgroundColor = .green
        page.identifier = ScreenRecordingWindowController.previewIdentifier
        let control = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        control.isReleasedWhenClosed = false; control.identifier = ScreenRecordingWindowController.identifier
        control.level = .floating; control.backgroundColor = .red
        page.orderFrontRegardless(); control.orderFrontRegardless()
        defer { page.close(); control.close() }
        try await Task.sleep(for: .milliseconds(200))
        let choices = try await ScreenRecordingCoordinator.catalog()
        #expect(choices.contains { $0.target == .display(displayID) })
        #expect(choices.contains { $0.target == .window(CGWindowID(page.windowNumber)) })
        #expect(!choices.contains { $0.target == .window(CGWindowID(control.windowNumber)) })
        let rect = ScreenCaptureGeometry.flipped(frame, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = NativeScreenRecordingEngine()
        #expect(engine.previewSession == nil && engine.audioLevel == 0)
        var options = ScreenRecordingOptions()
        options.showsCursor = false
        try await engine.start(target: .region(displayID: displayID, rect: rect), options: options, url: url)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await engine.elapsed() > 0)
        _ = try await engine.stop()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.2)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        let pixels = try #require(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpaceCreateDeviceRGB()))
        let offset = (pixels.height / 2 * pixels.width + pixels.width / 2) * 4
        #expect(pixels.bytes[offset] < 50)
        #expect(pixels.bytes[offset + 1] > 200)
        #expect(pixels.bytes[offset + 2] < 50)
        let mp4 = url.deletingPathExtension().appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4) }
        try await ScreenRecordingExporter(encoder: ScreenRecordingEncoder(worker: MediaWorker(timeout: 600))).export(source: url, destination: mp4, format: .mp4,
                                                   trim: .init(start: 0, end: duration)) { _ in }
        let exported = AVURLAsset(url: mp4)
        #expect(try await exported.load(.duration).seconds > 0.2)
        #expect(try await exported.loadTracks(withMediaType: .video).count == 1)
        await engine.cancel()
    }
}
