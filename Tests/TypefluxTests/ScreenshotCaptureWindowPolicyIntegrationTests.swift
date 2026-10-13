import AppKit
import XCTest
@testable import Typeflux

/// XCTest records runtime environment failures as skips, rather than successful captures.
final class ScreenshotCaptureWindowPolicyIntegrationTests: XCTestCase {
    func testRealCaptureKeepsAppPagePixelsBehindCaptureControls() async throws {
        try await ExclusiveUIStateLock.shared.withLock { @MainActor in
            try await ScreenshotCaptureWindowPolicyIntegrationTests.captureAppPagePixels()
        }
    }

    @MainActor
    private static func captureAppPagePixels() async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let application = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen Recording permission is unavailable") }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { throw XCTSkip("The main capture display is unavailable in this WindowServer session") }
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        defer {
            if let previousFrontmost, previousFrontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousFrontmost.activate(options: [.activateIgnoringOtherApps])
            }
        }
        application.activate(ignoringOtherApps: true)
        let area = screen.visibleFrame
        let pageFrame = CGRect(x: area.midX - 120, y: area.midY - 90, width: 240, height: 180)
        let page = NSWindow(contentRect: pageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        page.title = "Typeflux screenshot regression test"
        page.isOpaque = true
        page.backgroundColor = .green
        page.hasShadow = false
        page.contentView = SolidCaptureView(frame: CGRect(origin: .zero, size: pageFrame.size),
                                            color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        page.level = .screenSaver
        let control = ScreenshotFloatingPanel(frame: pageFrame)
        control.isOpaque = true
        control.backgroundColor = .red
        control.contentView = SolidCaptureView(frame: CGRect(origin: .zero, size: pageFrame.size),
                                               color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        defer {
            TypefluxNavigationTestSupport.closeWindow(control)
            TypefluxNavigationTestSupport.closeWindow(page)
        }
        page.orderFrontRegardless()
        page.displayIfNeeded()
        control.orderFrontRegardless()
        control.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let pageState = try onScreenState(page)
        let controlState = try onScreenState(control)
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen Recording permission was revoked") }
        let request = ScreenCaptureRequest(
            displays: .preferred(CGMainDisplayID()), resolution: .fitting(maxDimension: 640),
            windowExclusion: .screenshotControls
        )
        // Establish capture visibility before testing exclusions. A desktop or another
        // session at this sample cannot prove anything about the exclusion policy.
        let covered = try await captureSnapshot(ScreenCaptureService(captureControlWindowIDs: { [] }), request: request)
        let coveredPixel = try centerPixel(try XCTUnwrap(covered.displays.first), frame: pageFrame, screen: screen)
        guard coveredPixel[0] > 200, coveredPixel[1] < 50, coveredPixel[2] < 50 else {
            throw XCTSkip("Capture did not contain the red fixture: RGBA \(coveredPixel); \(pageState); \(controlState)")
        }
        let snapshot = try await captureSnapshot(ScreenCaptureService(), request: request)
        _ = try onScreenState(page)
        _ = try onScreenState(control)
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen Recording permission was revoked") }
        XCTAssertTrue(snapshot.windows.contains { $0.id == CGWindowID(page.windowNumber) })
        XCTAssertFalse(snapshot.windows.contains { $0.id == CGWindowID(control.windowNumber) })
        let pixel = try centerPixel(try XCTUnwrap(snapshot.displays.first), frame: pageFrame, screen: screen)
        // Once the red baseline is established, a wrong excluded capture is a real failure.
        XCTAssertLessThan(pixel[0], 50, "Excluded capture RGBA \(pixel)")
        XCTAssertGreaterThan(pixel[1], 200, "Excluded capture RGBA \(pixel)")
        XCTAssertLessThan(pixel[2], 50, "Excluded capture RGBA \(pixel)")
        XCTAssertGreaterThan(pixel[3], 250)
    }

    @MainActor
    private static func captureSnapshot(_ service: ScreenCaptureService,
                                        request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
        do { return try await service.snapshot(request) }
        catch ScreenCaptureError.permissionDenied { throw XCTSkip("Screen Recording permission was revoked before capture") }
    }

    @MainActor
    private static func onScreenState(_ window: NSWindow) throws -> String {
        guard window.windowNumber > 0 else { throw XCTSkip("The capture fixture has no WindowServer ID") }
        let id = CGWindowID(window.windowNumber)
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        guard let info = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
        else { throw XCTSkip("Capture fixture \(id) is absent from WindowServer") }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
        let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let state = "fixture \(id): onScreen=\(onScreen), layer=\(String(describing: layer))"
        guard onScreen, layer == window.level.rawValue, owner == ProcessInfo.processInfo.processIdentifier else {
            throw XCTSkip("WindowServer cannot present this process's capture fixture: \(state)")
        }
        return state
    }

    @MainActor
    private static func centerPixel(_ display: ScreenSnapshot.Display, frame: CGRect, screen: NSScreen) throws -> [UInt8] {
        let center = CGRect(x: frame.midX - 5, y: frame.midY - 5, width: 10, height: 10)
        let crop = ScreenCaptureGeometry.flipped(center, primaryDisplayHeight: screen.frame.height)
        let image = try ScreenshotImageExporter.crop(display, to: crop)
        let pixels = try XCTUnwrap(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        let offset = ((pixels.height / 2) * pixels.width + pixels.width / 2) * 4
        return Array(pixels.bytes[offset ..< offset + 4])
    }

    @MainActor
    private final class SolidCaptureView: NSView {
        let color: NSColor

        init(frame: NSRect, color: NSColor) {
            self.color = color
            super.init(frame: frame)
        }

        required init?(coder _: NSCoder) { return nil }

        override var isOpaque: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }
}
