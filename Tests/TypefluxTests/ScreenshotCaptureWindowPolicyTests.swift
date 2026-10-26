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
        let panels: [NSPanel] = [ScreenshotOverlayPanel(frame: frame), ScreenshotFloatingPanel(frame: frame)]
        defer { panels.forEach { $0.close() } }
        #expect(panels.allSatisfy { ScreenshotCaptureWindowPolicy.excludes($0) })
    }

    @Test func noticesAndCompletedPinsRemainCapturable() {
        let panel = NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        for identifier in [ScreenshotCaptureWindowPolicy.toastIdentifier,
                           ScreenshotCaptureWindowPolicy.tooltipIdentifier,
                           ScreenshotCaptureWindowPolicy.permissionIdentifier,
                           ScreenshotCaptureWindowPolicy.recordingToastIdentifier] {
            panel.identifier = identifier
            #expect(!ScreenshotCaptureWindowPolicy.excludes(panel))
        }
        panel.identifier = nil
        #expect(!ScreenshotCaptureWindowPolicy.excludes(panel))
        let pin = ScreenshotPinPanel(frame: frame)
        defer { pin.close() }
        #expect(!ScreenshotCaptureWindowPolicy.excludes(pin))
        // Native modal windows have no app-specific identifier. Avoid initializing
        // file dialogs here: their out-of-process service needs an application event loop.
        let dialog = NSAlert().window
        dialog.isReleasedWhenClosed = false
        #expect(!ScreenshotCaptureWindowPolicy.excludes(dialog))
        dialog.close()
    }

    @Test func `screenshot tooltips stay above the capture overlay and hide on exit`() throws {
        let owner = UUID()
        let otherOwner = UUID()
        let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        let controller = TooltipWindowController.shared
        controller.show(text: "Record screen", screenFrame: frame, yOffset: 10, owner: owner, level: level)
        let panel = try #require(NSApp.windows.first {
            $0.identifier == ScreenshotCaptureWindowPolicy.tooltipIdentifier
        })
        defer { controller.hide(owner: owner) }
        #expect(panel.isVisible)
        #expect(panel.level == level)
        #expect(ScreenshotCaptureWindowPolicy.excludes(panel))
        #expect(ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(panel.windowNumber)))
        controller.hide(owner: otherOwner)
        #expect(panel.isVisible)
        controller.hide(owner: owner)
        #expect(!panel.isVisible)
        controller.show(text: "App tooltip", screenFrame: frame, yOffset: 10, owner: owner)
        #expect(!ScreenshotCaptureWindowPolicy.excludes(panel))
        #expect(!ScreenshotCaptureWindowPolicy.excludedWindowIDs().contains(CGWindowID(panel.windowNumber)))
    }

}

extension ScreenshotCaptureWindowPolicyTests {
    @Test func capturePanelsAcceptInputDuringAModalDialog() throws {
        let alert = NSAlert()
        alert.messageText = "Keep this dialog open while capturing"
        let modal = alert.window
        modal.isReleasedWhenClosed = false
        let session = NSApp.beginModalSession(for: modal)
        let recording = ScreenRecordingWindowController()
        let panels = [ScreenshotOverlayPanel(frame: frame), ScreenshotFloatingPanel(frame: frame, becomesKey: true),
                      recording.makePanel(frame: frame), ScreenshotPinPanel(frame: frame)]
        defer {
            NSApp.endModalSession(session)
            panels.forEach { $0.close() }
            modal.close()
            recording.hide()
        }
        for panel in panels {
            let probe = ModalInputProbe(frame: CGRect(origin: .zero, size: frame.size))
            panel.contentView = probe
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(probe)
            #expect(panel.worksWhenModal)
            let mouse = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0
            ))
            // SwiftPM's helper owns the outer application loop. Dispatch native events
            // in the active modal session without starting a competing AppKit loop.
            NSApp.sendEvent(mouse)
            NSApp.sendEvent(key)
            #expect(probe.receivedMouse)
            #expect(probe.receivedKey)
            #expect(NSApp.modalWindow === modal, "Capturing must not dismiss the source dialog")
            panel.orderOut(nil)
        }
    }

    private final class ModalInputProbe: NSView {
        var receivedMouse = false
        var receivedKey = false
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with _: NSEvent) { receivedMouse = true }
        override func keyDown(with _: NSEvent) { receivedKey = true }
    }

    @Test func auxiliaryCapturePanelsWorkWhileTheSourceIsModal() throws {
        let parent = ScreenshotOverlayPanel(frame: frame)
        let beauty = ScreenshotBeautificationPanel()
        let guide = ScreenshotPermissionGuideController()
        defer { beauty.dismiss(); guide.dismiss(); parent.close() }
        parent.orderFrontRegardless()
        beauty.present(source: ScreenCaptureTestSupport.image(width: 80, height: 40), scale: 1,
                       settings: .init(), over: parent, apply: { _ in })
        #expect(try #require(beauty.panel).worksWhenModal)
        beauty.dismiss()
        guide.show(actions: .init(openSettings: {}, recheck: { false }, restart: {}, later: {}))
        #expect(try #require(guide.window).worksWhenModal)
    }

    @Test func recordingCanSelectSmallOwnAppPopupsAndCapsules() {
        let layer = NSWindow.Level.statusBar.rawValue
        #expect(ScreenRecordingCoordinator.isSelectableWindow(layer: layer, size: CGSize(width: 180, height: 32),
                                                              isOwnApplication: true))
        #expect(!ScreenRecordingCoordinator.isSelectableWindow(layer: layer, size: CGSize(width: 180, height: 32),
                                                               isOwnApplication: false))
        #expect(ScreenRecordingCoordinator.isSelectableWindow(layer: 0, size: CGSize(width: 300, height: 200),
                                                              isOwnApplication: false))
        #expect(!ScreenRecordingCoordinator.isSelectableWindow(layer: 0, size: CGSize(width: 50, height: 50),
                                                               isOwnApplication: false))
        for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: 10, height: 0),
                     CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            #expect(!ScreenRecordingCoordinator.isSelectableWindow(layer: layer, size: size, isOwnApplication: true))
        }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"))
    func progressiveNativeCaptureReportsFirstScreenLatency() async throws {
        try #require(CGPreflightScreenCaptureAccess())
        let displays = try ScreenCaptureContent.activeDisplays()
        let preferred = try #require(displays.last?.id)
        let start = ContinuousClock.now
        var received: [CGDirectDisplayID] = []
        let result = try await ScreenCaptureService().progressiveSnapshot(preferredDisplayID: preferred) { part in
            received.append(contentsOf: part.displays.map(\.id))
            print("PROGRESSIVE_CAPTURE displays=\(received.count) elapsed=\(start.duration(to: .now))")
        }
        #expect(received.first == preferred)
        #expect(Set(received) == Set(displays.map(\.id)))
        #expect(result.displays.map(\.id) == received)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"))
    func directCapturePreservesPixelsAcrossDisplaysAndMeasuresBothPaths() async throws {
        guard #available(macOS 26.0, *) else { return }
        try #require(CGPreflightScreenCaptureAccess())
        let screen = try #require(NSScreen.screens.first)
        let frame = CGRect(x: screen.visibleFrame.midX - 60, y: screen.visibleFrame.midY - 60, width: 120, height: 120)
        let page = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false; page.isOpaque = true
        page.backgroundColor = .green; page.level = .floating
        page.orderFrontRegardless()
        defer { page.close() }
        try await Task.sleep(for: .milliseconds(100))
        let refresh = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled else { return }
                tick += 1
                page.setFrame(frame.insetBy(dx: tick.isMultiple(of: 2) ? 0 : -1, dy: 0), display: true)
            }
        }
        defer { refresh.cancel() }
        let expected = try ScreenCaptureContent.activeDisplays()
        let primary = try #require((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        for direct in [false, true] {
            let service = direct ? ScreenCaptureService() : ScreenCaptureService(loadContent: ScreenCaptureContent.system)
            for attempt in 0..<3 {
                let began = ContinuousClock.now
                let snapshot = try await service.snapshot(.init(windowExclusion: .screenshotControls))
                print("CAPTURE_BENCH path=\(direct ? "direct" : "filtered") attempt=\(attempt) displays=\(snapshot.displays.count) elapsed=\(began.duration(to: .now))")
                #expect(Set(snapshot.displays.map(\.id)) == Set(expected.map(\.id)))
                for display in snapshot.displays {
                    let spec = try #require(expected.first { $0.id == display.id })
                    #expect(display.frame == spec.frame)
                    #expect(display.pixelSize == ScreenCaptureGeometry.pixelSize(pointSize: spec.frame.size,
                                                                                 scale: spec.scale, resolution: .native))
                }
                let display = try #require(snapshot.display(id: primary))
                let crop = ScreenCaptureGeometry.flipped(CGRect(x: frame.midX - 5, y: frame.midY - 5, width: 10, height: 10),
                                                        primaryDisplayHeight: screen.frame.height)
                let image = try ScreenshotImageExporter.crop(display, to: crop)
                let pixels = try #require(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpaceCreateDeviceRGB()))
                let offset = (pixels.height / 2 * pixels.width + pixels.width / 2) * 4
                #expect(pixels.bytes[offset] < 50 && pixels.bytes[offset + 1] > 200 && pixels.bytes[offset + 2] < 50)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"] == "1"),
          arguments: ["page", "launcher", "recording-preview", "recording-toast", "screenshot-toast", "permission", "tooltip", "pin"])
    func realCaptureKeepsAppPagePixelsBehindCaptureControls(_ kind: String) async throws {
        let isLauncher = kind == "launcher"
        let isRecordingToast = kind == "recording-toast"
        try #require(CGPreflightScreenCaptureAccess(),
                     "Grant screen recording access before running the real capture test")
        let screen = try #require(NSScreen.screens.first)
        let area = screen.visibleFrame
        let pageFrame = CGRect(x: area.midX - 120, y: area.midY - 90, width: 240, height: 180)
        let page: NSWindow = kind == "pin" ? ScreenshotPinPanel(frame: pageFrame) : isLauncher || isRecordingToast
            ? NSPanel(contentRect: pageFrame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
            : NSWindow(contentRect: pageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.identifier = isLauncher ? TypefluxWindowIdentity.askLauncherWindowIdentifier :
            (isRecordingToast ? ScreenshotCaptureWindowPolicy.recordingToastIdentifier :
                (kind == "recording-preview" ? ScreenRecordingWindowController.previewIdentifier : nil))
        if kind == "screenshot-toast" { page.identifier = ScreenshotCaptureWindowPolicy.toastIdentifier }
        if kind == "permission" { page.identifier = ScreenshotCaptureWindowPolicy.permissionIdentifier }
        if kind == "tooltip" { page.identifier = ScreenshotCaptureWindowPolicy.tooltipIdentifier }
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
