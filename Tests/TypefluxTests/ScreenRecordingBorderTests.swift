import AppKit
import AVFoundation
import Testing
@testable import Typeflux

@Suite("Recording border stays outside captured pixels", .exclusiveUIState)
@MainActor
struct ScreenRecordingBorderTests {
    @Test(arguments: [1, 2], [false, true])
    func `all border pixels stay outside the target at both display scales`(scale: Int, paused: Bool) throws {
        let target = CGRect(x: 0, y: 0, width: 160, height: 100)
        let frame = ScreenRecordingBorderView.panelFrame(around: target)
        let view = ScreenRecordingBorderView(frame: CGRect(origin: .zero, size: frame.size))
        view.paused = paused
        let context = try #require(CGContext(
            data: nil, width: Int(frame.width) * scale, height: Int(frame.height) * scale,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        let pixels = try #require(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpaceCreateDeviceRGB()))
        var totalPainted = 0
        var capturedPainted = 0
        let localTarget = target.offsetBy(dx: -frame.minX, dy: -frame.minY)
        for y in 0 ..< pixels.height {
            for x in 0 ..< pixels.width where pixels.bytes[(y * pixels.width + x) * 4 + 3] > 0 {
                totalPainted += 1
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale),
                                    y: (CGFloat(y) + 0.5) / CGFloat(scale))
                if localTarget.contains(point) {
                    capturedPainted += 1
                }
            }
        }
        #expect(totalPainted > 0, "The visible recording indicator must still be drawn")
        #expect(capturedPainted == 0, "Neither the stroke nor its corner brackets may enter the video")
        try ScreenshotSnapshotSupport.write(image, name: "recording-border-\(scale)x-\(paused ? "paused" : "live")")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"))
    func `native recording has clean edges even when its border is not excluded`() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let displayID = try #require((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value)
        let frame = CGRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.midY - 90,
                           width: 240, height: 180)
        // A synthetic page extending past the recording boundary keeps desktop content out of the fixture.
        let page = NSWindow(contentRect: frame.insetBy(dx: -20, dy: -20), styleMask: .borderless,
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false; page.backgroundColor = .green; page.level = .floating
        page.orderFrontRegardless()
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let mp4 = source.deletingPathExtension().appendingPathExtension("mp4")
        defer {
            presenter.hide(); page.close()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: mp4)
        }
        try await Task.sleep(for: .milliseconds(200))
        let rect = ScreenCaptureGeometry.flipped(frame, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        presenter.outline(.region(displayID: displayID, rect: rect))
        let border = try #require(presenter.border)
        // AppKit rounds fractional window origins outward; the margin must remain intact.
        #expect(border.frame.contains(ScreenRecordingBorderView.panelFrame(around: frame)))
        #expect(ScreenshotCaptureWindowPolicy.excludes(border))
        // Deliberately bypass exclusion to exercise the boundary itself, including the first frames.
        border.identifier = nil
        var options = ScreenRecordingOptions()
        options.showsCursor = false
        let engine = NativeScreenRecordingEngine()
        try await engine.start(target: .region(displayID: displayID, rect: rect), options: options, url: source)
        try await Task.sleep(for: .milliseconds(250))
        (border.contentView as? ScreenRecordingBorderView)?.paused = true
        try await Task.sleep(for: .milliseconds(250))
        _ = try await engine.stop()
        let count = try await Self.checkEveryFrame(source)
        #expect(count > 2)
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        try await ScreenRecordingExporter().export(source: source, destination: mp4, format: .mp4,
                                                   trim: .init(start: 0, end: duration)) { _ in }
        #expect(try await Self.checkEveryFrame(mp4) > 2)
        await engine.cancel()
        await presenter.deviceTask?.value
    }

    private static func checkEveryFrame(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        var contaminated = 0
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            count += 1
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let data = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0 ..< height {
                    for x in 0 ..< width where x < 8 || y < 8 || x >= width - 8 || y >= height - 8 {
                        let offset = y * stride + x * 4
                        if data[offset + 2] > 80 || data[offset + 1] < 150 {
                            contaminated += 1
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        #expect(reader.status == .completed)
        #expect(contaminated == 0, "Every frame edge must contain only the green page, without red/orange borders")
        return count
    }
}
