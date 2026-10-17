import AppKit
import Testing
@testable import Typeflux

@Suite("Screenshot window exclusions", .exclusiveUIState)
@MainActor
struct ScreenshotCaptureWindowPolicyTests {
    private let frame = CGRect(x: 200, y: 200, width: 240, height: 180)

    init() {
        _ = NSApplication.shared
    }

    @Test func `window IDs outside the Quartz range are ignored`() {
        for number in [Int.min, -1, 0, Int(UInt32.max) + 1, Int.max] {
            #expect(ScreenshotCaptureWindowPolicy.captureWindowID(number) == nil)
        }
        #expect(ScreenshotCaptureWindowPolicy.captureWindowID(1) == 1)
        #expect(ScreenshotCaptureWindowPolicy.captureWindowID(Int(UInt32.max)) == UInt32.max)
    }

    private final class NumberedPanel: NSPanel {
        var reportedNumber: Int?
        override var windowNumber: Int {
            reportedNumber ?? super.windowNumber
        }
    }

    @Test func `visible recording controls with oversized numbers do not crash exclusion`() {
        let panel = NumberedPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.identifier = ScreenRecordingWindowController.identifier
        panel.orderFrontRegardless()
        let original = panel.windowNumber
        defer { panel.reportedNumber = nil; panel.close() }
        #expect(ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(original)))
        panel.reportedNumber = Int(UInt32.max) + 1
        #expect(!ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(original)))
        panel.reportedNumber = original
        #expect(ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(original)))
    }

    @Test func appPagesRemainCapturable() {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for identifier in ["ask-launcher", "ask-conversations", "settings", "word-cards", "notes", "ask-answer",
                           "recording-preview"] {
            window.identifier = .init("ai.gulu.app.typeflux.window.\(identifier)")
            #expect(!ScreenshotCaptureWindowPolicy.excludes(window))
        }
        // Classification must not depend on localized or user-entered titles.
        window.identifier = nil
        window.title = "Screenshot"
        #expect(!ScreenshotCaptureWindowPolicy.excludes(window))
    }

    @Test func capturePanelsAreExcluded() {
        let panels: [NSPanel] = [ScreenshotOverlayPanel(frame: frame), ScreenshotFloatingPanel(frame: frame),
                                 ScreenshotPinPanel(frame: frame)]
        defer { panels.forEach { $0.close() } }
        #expect(panels.allSatisfy { ScreenshotCaptureWindowPolicy.excludes($0) })
    }

    @Test func captureNoticesAreExcluded() {
        let panel = NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        for identifier in [ScreenshotCaptureWindowPolicy.toastIdentifier,
                           ScreenshotCaptureWindowPolicy.permissionIdentifier] {
            panel.identifier = identifier
            #expect(ScreenshotCaptureWindowPolicy.excludes(panel))
        }
        panel.identifier = nil
        #expect(!ScreenshotCaptureWindowPolicy.excludes(panel))
        panel.identifier = ScreenshotCaptureWindowPolicy.recordingToastIdentifier
        #expect(!ScreenshotCaptureWindowPolicy.excludes(panel))
    }

    @Test func onlyVisibleCaptureControlsAreListed() {
        _ = NSApplication.shared
        let control = ScreenshotFloatingPanel(frame: frame)
        let page = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        defer {
            control.close()
            page.close()
        }
        control.orderFrontRegardless()
        page.orderFrontRegardless()
        let ids = ScreenshotCaptureWindowPolicy.excludedWindowIDs()
        #expect(ids.contains(CGWindowID(control.windowNumber)))
        #expect(!ids.contains(CGWindowID(page.windowNumber)))
        control.orderOut(nil)
        #expect(!ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(control.windowNumber)))
    }

    @Test func explicitCaptureKeepsTheVisibleLauncherSelectableAndOpen() async throws {
        let launcher = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        launcher.identifier = TypefluxWindowIdentity.askLauncherWindowIdentifier
        launcher.hidesOnDeactivate = false
        launcher.isReleasedWhenClosed = false
        let control = ScreenshotFloatingPanel(frame: frame)
        let overlay = ScreenshotOverlayController(primaryDisplayHeight: { 768 }, pointerLocation: { .zero })
        defer {
            overlay.dismiss()
            control.close()
            launcher.close()
        }
        launcher.orderFrontRegardless()
        control.orderFrontRegardless()
        let launcherID = CGWindowID(launcher.windowNumber)
        let controlID = CGWindowID(control.windowNumber)
        let processID = ProcessInfo.processInfo.processIdentifier
        let content = ScreenCaptureContent(
            displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 1024, height: 768), scale: 1)],
            windows: [ScreenCaptureTestSupport.window(controlID, processID: processID, frame: frame),
                      ScreenCaptureTestSupport.window(launcherID, processID: processID, frame: frame)]
        ) { _, excluded, size in
            #expect(excluded == [controlID], "The launcher must remain in the captured pixels")
            return ScreenCaptureTestSupport.image(width: size.width, height: size.height)
        }
        let service = ScreenCaptureService(permission: FakeScreenCapturePermission(granted: true),
                                           loadContent: { content })
        let snapshot = try await service.snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
        #expect(snapshot.windows.map(\.id) == [launcherID])
        let display = try #require(snapshot.displays.first)
        var selection = ScreenshotSelection(
            displayFrame: display.frame,
            scale: display.scale,
            windows: snapshot.windows
        )
        let point = CGPoint(x: frame.midX, y: frame.midY)
        selection.pointerMoved(to: point)
        #expect(selection.hovered == frame)
        _ = selection.mouseDown(at: point)
        #expect(selection.mouseUp(at: point) == .committed)
        #expect(selection.rect == frame)
        overlay.present(snapshot) { _ in }
        #expect(launcher.isVisible)
        overlay.dismiss()
        #expect(launcher.isVisible)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"),
          arguments: ["page", "launcher", "recording-preview", "recording-toast"])
    func realCaptureKeepsAppPagePixelsBehindCaptureControls(_ kind: String) async throws {
        let isLauncher = kind == "launcher"
        let isRecordingToast = kind == "recording-toast"
        try #require(CGPreflightScreenCaptureAccess(),
                     "Grant screen recording access before running the real capture test")
        let screen = try #require(NSScreen.screens.first)
        let area = screen.visibleFrame
        let pageFrame = CGRect(x: area.midX - 120, y: area.midY - 90, width: 240, height: 180)
        let page: NSWindow = isLauncher || isRecordingToast
            ? NSPanel(contentRect: pageFrame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
            : NSWindow(contentRect: pageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.identifier = isLauncher ? TypefluxWindowIdentity.askLauncherWindowIdentifier :
            (isRecordingToast ? ScreenshotCaptureWindowPolicy.recordingToastIdentifier :
                (kind == "recording-preview" ? ScreenRecordingWindowController.previewIdentifier : nil))
        (page as? NSPanel)?.hidesOnDeactivate = false
        page.isReleasedWhenClosed = false
        page.title = "Typeflux screenshot regression test"
        page.isOpaque = true
        page.backgroundColor = .green
        page.level = .floating
        let control = ScreenshotFloatingPanel(frame: pageFrame)
        control.isOpaque = true
        control.backgroundColor = .red
        defer {
            control.close()
            page.close()
        }
        page.orderFrontRegardless()
        control.orderFrontRegardless()
        page.displayIfNeeded()
        control.displayIfNeeded()
        // Let the window server commit both surfaces before ScreenCaptureKit freezes them.
        try await Task.sleep(nanoseconds: 200_000_000)
        let snapshot = try await ScreenCaptureService().snapshot(ScreenCaptureRequest(
            displays: .preferred(CGMainDisplayID()), resolution: .fitting(maxDimension: 640),
            windowExclusion: .screenshotControls
        ))
        #expect(snapshot.windows.contains { $0.id == CGWindowID(page.windowNumber) })
        #expect(!snapshot.windows.contains { $0.id == CGWindowID(control.windowNumber) })
        let display = try #require(snapshot.displays.first)
        let center = CGRect(x: pageFrame.midX - 5, y: pageFrame.midY - 5, width: 10, height: 10)
        let crop = ScreenCaptureGeometry.flipped(center, primaryDisplayHeight: screen.frame.height)
        let image = try ScreenshotImageExporter.crop(display, to: crop)
        let pixels = try #require(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        let offset = ((pixels.height / 2) * pixels.width + pixels.width / 2) * 4
        #expect(pixels.bytes[offset] < 50)
        #expect(pixels.bytes[offset + 1] > 200)
        #expect(pixels.bytes[offset + 2] < 50)
    }
}
