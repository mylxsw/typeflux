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
}
