import AppKit
import Testing
@testable import Typeflux

@Suite("Screenshot window exclusions", .exclusiveUIState)
@MainActor
struct ScreenshotCaptureWindowPolicyTests {
    private let frame = CGRect(x: 200, y: 200, width: 240, height: 180)

    init() { _ = NSApplication.shared }

    @Test func appPagesRemainCapturable() {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for identifier in ["ask-conversations", "settings", "word-cards", "notes", "ask-answer"] {
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

    @Test func launcherAndCaptureNoticesAreExcluded() {
        let panel = NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        for identifier in [ScreenshotCaptureWindowPolicy.launcherIdentifier,
                           ScreenshotCaptureWindowPolicy.toastIdentifier,
                           ScreenshotCaptureWindowPolicy.permissionIdentifier] {
            panel.identifier = identifier
            #expect(ScreenshotCaptureWindowPolicy.excludes(panel))
        }
        panel.identifier = nil
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

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func realCaptureKeepsAppPagePixelsBehindCaptureControls() async throws {
        let screen = try #require(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }, "The fixture must use the same display as the capture request")
        let area = screen.visibleFrame
        let pageFrame = CGRect(x: area.midX - 120, y: area.midY - 90, width: 240, height: 180)
        let page = NSWindow(contentRect: pageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        page.title = "Typeflux screenshot regression test"
        page.isOpaque = true
        page.backgroundColor = .green
        // Keep the fixture above windows left by earlier suites. The excluded red control
        // uses the same level and is ordered above this green page explicitly.
        page.level = .screenSaver
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
