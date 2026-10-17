import AppKit
import AVFoundation
import QuartzCore
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Screen recording views", .exclusiveUIState)
@MainActor
struct ScreenRecordingVisualTests {
    final class Devices: ScreenRecordingDevicePreviewing {
        let session = AVCaptureSession()
        var level: Float {
            0.45
        }

        var stops = 0
        func authorizationStatus(for _: AVMediaType) -> AVAuthorizationStatus {
            .authorized
        }

        func configure(camera _: Bool, microphone _: Bool) async {}
        func stop() async {
            stops += 1
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func `toolbar capsule editor and toast use the approved surfaces`(style: InterfaceStyle, dark: Bool) async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.options.systemAudio = true
        fixture.model.options.microphone = true
        let toolbar = try await ScreenshotSnapshotSupport.bitmap(
            of: ScreenRecordingToolbar(model: fixture.model, levelProvider: { 0.6 }, close: {}, chooseDirectory: {})
                .environment(\.interfaceStyle, style),
            dark: dark
        )
        #expect(toolbar.size.height < 120)
        #expect(toolbar.size.width < 1000)
        try ScreenshotSnapshotSupport.write(
            #require(toolbar.cgImage),
            name: "recording-toolbar-\(style.rawValue)-\(dark ? "dark" : "light")"
        )
        fixture.engine.movie = Self.reviewMovie
        fixture.model.options.countdown = 0
        fixture.model.start()
        await fixture.model.pendingTask?.value
        for paused in [false, true] {
            if paused {
                fixture.model.togglePause()
            }
            let capsule = try await ScreenshotSnapshotSupport.bitmap(
                of: ScreenRecordingCapsule(model: fixture.model, levelProvider: { 0.4 }, close: {}).environment(
                    \.interfaceStyle,
                    style
                ),
                dark: dark
            )
            #expect(capsule.size.height < 100)
            try ScreenshotSnapshotSupport.write(
                #require(capsule.cgImage),
                name: "recording-\(paused ? "paused" : "capsule")-\(style.rawValue)-\(dark ? "dark" : "light")"
            )
        }
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        for _ in 0 ..< 100 where fixture.model.media.thumbnails.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        fixture.model.setTrimStart(1.8)
        fixture.model.setTrimEnd(15.2)
        let editor = try await ScreenshotSnapshotSupport.bitmap(
            of: ScreenRecordingPreviewView(model: fixture.model).frame(width: 920, height: 632).environment(
                \.interfaceStyle,
                style
            ),
            dark: dark
        )
        try ScreenshotSnapshotSupport.write(
            #require(editor.cgImage),
            name: "recording-editor-\(style.rawValue)-\(dark ? "dark" : "light")"
        )
        fixture.model.options.format = .gif
        fixture.model.resetTrim()
        #expect(!fixture.model.canExport)
        let gif = try await ScreenshotSnapshotSupport.bitmap(
            of: ScreenRecordingPreviewView(model: fixture.model).frame(width: 920, height: 632).environment(
                \.interfaceStyle,
                style
            ),
            dark: dark
        )
        try ScreenshotSnapshotSupport.write(
            #require(gif.cgImage),
            name: "recording-gif-editor-\(style.rawValue)-\(dark ? "dark" : "light")"
        )
        let toastModel = ScreenRecordingToastModel()
        toastModel.start(try #require(fixture.model.sourceURL), thumbnail: AskAttachmentFixture.image(width: 160, height: 100))
        await toastModel.task?.value
        let toast = try await ScreenshotSnapshotSupport.bitmap(
            of: ScreenRecordingToastView(model: toastModel, duration: 13.4,
                                         recovery: false, close: {}).frame(
                width: 440,
                height: 116
            ).environment(\.interfaceStyle, style),
            dark: dark
        )
        try ScreenshotSnapshotSupport.write(
            #require(toast.cgImage),
            name: "recording-toast-\(style.rawValue)-\(dark ? "dark" : "light")"
        )
        await fixture.clean()
    }

    @Test func `options match MP4 and GIF controls with legacy preferences`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.options.framesPerSecond = 15
        for format in ScreenRecordingFormat.allCases {
            fixture.model.options.format = format
            let image = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingOptionsPopover(
                model: fixture.model,
                chooseDirectory: {}
            ).padding(12))
            #expect(image.size.width == 374)
            try ScreenshotSnapshotSupport.write(#require(image.cgImage), name: "recording-options-" + format.rawValue)
        }
        fixture.model.options.format = .gif
        fixture.engine.seconds = 26
        fixture.model.options.countdown = 0
        fixture.model.start(); await fixture.model.pendingTask?.value
        try await Task.sleep(for: .milliseconds(300))
        let limit = try await ScreenshotSnapshotSupport.bitmap(of: ScreenRecordingCapsule(
            model: fixture.model,
            close: {}
        ))
        try ScreenshotSnapshotSupport.write(#require(limit.cgImage), name: "recording-gif-limit")
        #expect(fixture.model.elapsed == 26)
        await fixture.clean()
    }

    @Test func `native surfaces exclude every control and retain capsule position after pause`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let devices = Devices()
        let presenter = ScreenRecordingWindowController(preview: devices)
        await fixture.setup()
        presenter.show(fixture.model)
        fixture.model.select(ScreenRecordingChoice(
            id: "region",
            title: "Region",
            target: .region(displayID: 1, rect: CGRect(x: 100, y: 100, width: 560, height: 340)),
            frame: CGRect(x: 100, y: 100, width: 560, height: 340)
        ))
        #expect(try ScreenshotCaptureWindowPolicy.excludes(#require(presenter.window)))
        #expect(presenter.selectionPanels.allSatisfy(ScreenshotCaptureWindowPolicy.excludes))
        #expect(!presenter.selectionPanels.isEmpty)
        presenter.outline(fixture.model.selectedSource?.target)
        #expect(try ScreenshotCaptureWindowPolicy.excludes(#require(presenter.border)))
        #expect(presenter.border?.ignoresMouseEvents == true)
        fixture.model.options.countdown = 0
        fixture.model.start()
        await fixture.model.pendingTask?.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(presenter.selectionPanels.isEmpty)
        let controls = try #require(presenter.window)
        #expect(!controls.styleMask.contains(.titled))
        controls.setFrameOrigin(CGPoint(x: 300, y: 100))
        fixture.model.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        #expect((presenter.border?.contentView as? ScreenRecordingBorderView)?.paused == true)
        fixture.model.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(presenter.window === controls)
        #expect(presenter.window?.frame.origin == CGPoint(x: 300, y: 100))
        presenter.indicator("Ⅱ 00:01"); presenter.indicator(nil)
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        try await Task.sleep(for: .milliseconds(120))
        #expect(presenter.window?.styleMask.contains(.titled) == true)
        fixture.model.cancel()
        await fixture.model.pendingTask?.value
        presenter.hide()
        await presenter.deviceTask?.value
        #expect(devices.stops > 0)
        await fixture.clean()
    }

    @Test func `appearance and five languages keep actions inside the toolbar`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let files = ScreenRecordingFiles(root: fixture.root.appendingPathComponent("sessions"))
        let session = try files.createSession(options: ScreenRecordingOptions())
        try Data([1]).write(to: session.appendingPathComponent("source.mov"))
        await fixture.setup()
        #expect(fixture.model.recovered.count == 1)
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        let settings = SettingsStore(defaults: defaults)
        settings.appearanceMode = .light
        let presenter = ScreenRecordingWindowController(settings: settings, preview: Devices())
        presenter.show(fixture.model)
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            try await Task.sleep(for: .milliseconds(100))
            let window = try #require(presenter.window)
            #expect(window.appearance?.name == .aqua)
            #expect(window.frame.height < 200)
            #expect(window.contentView?.fittingSize.width ?? 0 <= window.frame.width)
        }
        settings.appearanceMode = .dark
        try await Task.sleep(for: .milliseconds(100))
        #expect(presenter.window?.appearance?.name == .darkAqua)
        presenter.hide()
        await presenter.deviceTask?.value
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

    @Test func `native editor review screenshots`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RECORDING_WINDOW_SNAPSHOTS"] else { return }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        let settings = SettingsStore(defaults: defaults)
        let presenter = ScreenRecordingWindowController(settings: settings, preview: Devices())
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        await fixture.recording()
        fixture.engine.movie = Self.reviewMovie
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        presenter.show(fixture.model)
        try await Task.sleep(for: .seconds(1))
        fixture.model.setTrimStart(1.8); fixture.model.setTrimEnd(15.2)
        for style in InterfaceStyle.allCases {
            settings.interfaceStyle = style
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                try await capture(
                    #require(presenter.window),
                    directory: directory,
                    name: "recording-native-editor-\(style.rawValue)-\(dark ? "dark" : "light")"
                )
            }
        }
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    static func reviewMovie(_ url: URL) async throws {
        var options = ScreenRecordingOptions()
        options.systemAudio = true
        let writer = try ScreenRecordingWriter(url: url, size: ScreenshotSnapshotSupport.screenSize, options: options)
        let image = ScreenshotSnapshotSupport.sampleScreen()
        for index in 0 ..< 12 {
            let time = 100 + Double(index) * 3
            let sample = try ScreenRecordingMediaTests.videoSample(at: time, width: image.width, height: image.height)
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ))
            context.draw(image, in: CGRect(origin: .zero, size: ScreenshotSnapshotSupport.screenSize))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            writer.offer(sample, track: .screen, hostTime: time)
            try writer.offer(ScreenRecordingMediaTests.audioSample(at: time), track: .systemAudio, hostTime: time)
            _ = await writer.elapsed(at: time)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await writer.finish(at: 138.6)
    }

    private func capture(_ window: NSWindow, directory: String, name: String) async throws {
        let backdrop = NSWindow(
            contentRect: window.frame.insetBy(dx: -100, dy: -100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        backdrop.order(.below, relativeTo: window.windowNumber)
        defer { backdrop.orderOut(nil); backdrop.close() }
        try await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(250))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x",
            "-o",
            "-l",
            String(window.windowNumber),
            URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path
        ]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
    }
}
