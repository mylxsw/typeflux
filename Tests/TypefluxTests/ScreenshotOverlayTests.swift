import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotOverlayTests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key

    private static func display(id: CGDirectDisplayID = 1, frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100),
                                scale: CGFloat = 2) -> ScreenSnapshot.Display {
        ScreenSnapshot.Display(id: id, frame: frame, scale: scale,
                               image: ScreenCaptureTestSupport.image(width: Int(frame.width * scale),
                                                                     height: Int(frame.height * scale), gray: 0))
    }

    private func makeView(windows: [ScreenSnapshot.Window] = []) -> (ScreenshotOverlayView,
                                                                     () -> [ScreenshotOverlayView.LocalEvent]) {
        let view = ScreenshotOverlayView(display: Self.display(), windows: windows)
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        return (view, { events })
    }

    private func chrome(of view: ScreenshotOverlayView) throws -> ScreenshotOverlayChromeView {
        try XCTUnwrap(view.subviews.lazy.compactMap { $0 as? ScreenshotOverlayChromeView }.first)
    }

    // MARK: View

    func testFramingDrawsTheLoupeThenHandlesAndToolbar() throws {
        let (view, events) = makeView()
        XCTAssertTrue(view.isFlipped)
        XCTAssertTrue(view.acceptsFirstResponder)

        view.pointerMoved(to: CGPoint(x: 50, y: 40))
        var model = try chrome(of: view).model
        XCTAssertTrue(view.showsLoupe)
        XCTAssertEqual(model.pointer, CGPoint(x: 50, y: 40))
        let loupe = try XCTUnwrap(model.loupe)
        XCTAssertEqual(loupe.coordinates, "50, 40")
        XCTAssertEqual(loupe.color, "#000000")
        XCTAssertEqual(loupe.imageSize, CGSize(width: 11, height: 9))
        XCTAssertNil(view.toolbar, "No toolbar before a region is chosen")

        view.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 110, y: 60))
        model = try chrome(of: view).model
        XCTAssertEqual(model.selection, CGRect(x: 10, y: 10, width: 100, height: 50))
        XCTAssertFalse(model.handles, "No handles while drawing")
        XCTAssertNotNil(model.loupe, "The loupe stays while drawing")
        XCTAssertNil(view.toolbar)

        view.mouseUp(at: CGPoint(x: 110, y: 60))
        model = try chrome(of: view).model
        XCTAssertEqual(events(), [.committed])
        XCTAssertTrue(model.handles)
        XCTAssertEqual(view.toolbar?.isHidden, false)
        XCTAssertEqual(model.sizeLabel, "100 × 50 pt · 200 × 100 px")
        XCTAssertNil(model.loupe)
        XCTAssertNil(model.pointer)
    }

    func testLoupeAtTheCornerShowsOnlyPixelsOnTheImage() throws {
        let (view, _) = makeView()
        view.pointerMoved(to: .zero)

        let loupe = try XCTUnwrap(chrome(of: view).model.loupe)
        XCTAssertEqual(loupe.imageOffset, CGPoint(x: 5, y: 4))
        XCTAssertEqual(loupe.imageSize, CGSize(width: 6, height: 5))
    }

    func testKeysCopySaveCancelAndSelectAll() {
        let (view, events) = makeView()

        XCTAssertTrue(view.handleKeyDown(Key.returnKey, modifiers: []))
        XCTAssertTrue(events().isEmpty, "Nothing to copy yet")

        XCTAssertTrue(view.handleKeyDown(Key.keyA, modifiers: .command))
        XCTAssertEqual(view.selection.rect, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(view.handleKeyDown(Key.returnKey, modifiers: []))
        XCTAssertTrue(view.handleKeyDown(Key.enter, modifiers: []))
        XCTAssertTrue(view.handleKeyDown(Key.keyC, modifiers: .command))
        XCTAssertTrue(view.handleKeyDown(Key.keyS, modifiers: .command))
        XCTAssertTrue(view.handleKeyDown(Key.escape, modifiers: []))
        let all = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(events(), [.committed, .finish(.copy, all), .finish(.copy, all), .finish(.copy, all),
                                  .finish(.save, all), .cancelled])

        XCTAssertFalse(view.handleKeyDown(Key.keyC, modifiers: []), "Plain C means nothing")
        XCTAssertFalse(view.handleKeyDown(Key.keyS, modifiers: []))
        XCTAssertFalse(view.handleKeyDown(99, modifiers: []))
        XCTAssertTrue(view.handleKeyDown(Key.keyA, modifiers: []), "Plain A picks the arrow")
        XCTAssertEqual(view.editor.tool, .arrow)
    }

    func testArrowsNudge() {
        let (view, _) = makeView()
        view.mouseDown(at: CGPoint(x: 50, y: 50), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 100, y: 80))
        view.mouseUp(at: CGPoint(x: 100, y: 80))

        view.handleKeyDown(Key.arrowRight, modifiers: [])
        view.handleKeyDown(Key.arrowDown, modifiers: .shift)
        XCTAssertEqual(view.selection.rect?.origin, CGPoint(x: 51, y: 60))
        view.handleKeyDown(Key.arrowLeft, modifiers: .shift)
        view.handleKeyDown(Key.arrowUp, modifiers: [])
        XCTAssertEqual(view.selection.rect?.origin, CGPoint(x: 41, y: 59))
    }

    func testSpaceMovesTheRegionWhileDrawing() {
        let (view, _) = makeView()
        view.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 50, y: 30))

        view.handleKeyDown(Key.space, modifiers: [])
        XCTAssertTrue(view.spaceHeld)
        view.mouseDragged(to: CGPoint(x: 70, y: 50))
        XCTAssertEqual(view.selection.rect, CGRect(x: 30, y: 30, width: 40, height: 20))

        view.handleKeyUp(Key.space)
        XCTAssertFalse(view.spaceHeld)
        view.handleKeyUp(Key.keyA)
    }

    func testDoubleClickInsideCopies() {
        let (view, events) = makeView()
        view.selectAll()

        view.mouseDown(at: CGPoint(x: 20, y: 20), clickCount: 2)

        XCTAssertEqual(events(), [.committed, .finish(.copy, CGRect(x: 0, y: 0, width: 200, height: 100))])
    }

    func testShiftCopiesTheColorOnlyWhileTheLoupeShows() {
        let (view, events) = makeView()
        view.handleFlagsChanged(.shift)
        XCTAssertTrue(events().isEmpty, "No pointer, no loupe")
        view.handleFlagsChanged([])

        view.pointerMoved(to: CGPoint(x: 30, y: 30))
        view.handleFlagsChanged(.shift)
        view.handleFlagsChanged([.shift, .command])
        XCTAssertEqual(events(), [.colorPicked("#000000")], "Once per press")

        view.handleFlagsChanged([])
        view.selectAll()
        view.handleFlagsChanged(.shift)
        XCTAssertEqual(events().last, .committed, "Not once a region is chosen")
    }

    func testClearSelectionAndReleaseImage() {
        let (view, _) = makeView()
        view.selectAll()

        view.clearSelection()
        XCTAssertNil(view.selection.rect)
        view.releaseImage()
        XCTAssertNil(view.layer?.sublayers?.first?.contents)
    }

    func testRealEventsReachTheHandlers() throws {
        let (view, events) = makeView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: true)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clicks, pressure: 1))
        }
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }

        // Window coordinates grow upward; the view's grow downward.
        view.mouseMoved(with: try mouse(.mouseMoved, CGPoint(x: 20, y: 80)))
        XCTAssertEqual(view.selection.pointer, CGPoint(x: 20, y: 20))
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 20, y: 80)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 120, y: 30)))
        view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 120, y: 30)))
        XCTAssertEqual(view.selection.rect, CGRect(x: 20, y: 20, width: 100, height: 50))

        view.keyDown(with: try key(.keyDown, Key.space))
        view.keyUp(with: try key(.keyUp, Key.space))
        view.keyDown(with: try key(.keyDown, 99))
        XCTAssertTrue(view.performKeyEquivalent(with: try key(.keyDown, Key.keyC, .command)))
        XCTAssertFalse(view.performKeyEquivalent(with: try key(.keyDown, Key.keyC)))
        view.flagsChanged(with: try key(.flagsChanged, 56, .shift))
        view.mouseExited(with: try mouse(.mouseMoved, CGPoint(x: 300, y: 300)))
        XCTAssertNil(view.selection.pointer)
        view.rightMouseDown(with: try mouse(.rightMouseDown, CGPoint(x: 20, y: 20)))

        XCTAssertEqual(events(), [.committed, .finish(.copy, CGRect(x: 20, y: 20, width: 100, height: 50)),
                                  .cancelled])
    }

    func testChromeDrawsEveryPart() throws {
        let chrome = ScreenshotOverlayChromeView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(chrome.hitTest(CGPoint(x: 10, y: 10)))
        let image = ScreenCaptureTestSupport.image(width: 11, height: 9)
        chrome.model = .init(selection: CGRect(x: 20, y: 0, width: 200, height: 280), hovered: nil, handles: true,
                             sizeLabel: "200 × 280", pointer: CGPoint(x: 100, y: 100),
                             loupe: .init(frame: CGRect(x: 120, y: 120, width: 110, height: 128), image: image,
                                          imageOffset: .zero, imageSize: CGSize(width: 11, height: 9),
                                          coordinates: "100, 100", color: "#808080"))
        let bitmap = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
        chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / chrome.bounds.width
        // The loupe's dark body is drawn where it was placed.
        XCTAssertGreaterThan(bitmap.colorAt(x: Int(200 * scale), y: Int(130 * scale))?.alphaComponent ?? 0, 0.5)

        chrome.model = .init(hovered: CGRect(x: 10, y: 10, width: 50, height: 50), sizeLabel: "50 × 50")
        let hovered = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
        chrome.cacheDisplay(in: chrome.bounds, to: hovered)
        // The hovered window's outline, and nothing in the middle of it.
        XCTAssertGreaterThan(hovered.colorAt(x: Int(11 * scale), y: Int(35 * scale))?.alphaComponent ?? 0, 0.5)
        XCTAssertEqual(hovered.colorAt(x: Int(35 * scale), y: Int(50 * scale))?.alphaComponent ?? 1, 0)
    }

    func testToolbarGoesBelowAboveOrInside() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 100, height: 22)

        XCTAssertEqual(ScreenshotOverlayChromeView.toolbarFrame(for: CGRect(x: 100, y: 50, width: 200, height: 100),
                                                             size: size, in: bounds).origin, CGPoint(x: 200, y: 158))
        XCTAssertEqual(ScreenshotOverlayChromeView.toolbarFrame(for: CGRect(x: 100, y: 200, width: 200, height: 95),
                                                             size: size, in: bounds).origin, CGPoint(x: 200, y: 170))
        XCTAssertEqual(ScreenshotOverlayChromeView.toolbarFrame(for: bounds, size: size, in: bounds).origin,
                       CGPoint(x: 292, y: 270))
        XCTAssertGreaterThan(ScreenshotOverlayChromeView.pillSize(for: "100 × 50").width, 16)
    }

    // MARK: Controller

    private func snapshot() -> ScreenSnapshot {
        ScreenSnapshot(displays: [
            Self.display(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2),
            Self.display(id: 2, frame: CGRect(x: 200, y: 0, width: 300, height: 150), scale: 1)
        ], windows: [])
    }

    func testControllerShowsOnePanelPerDisplayAndConvertsRegions() throws {
        var pointer = CGPoint(x: 250, y: 20)
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { pointer })
        var events: [ScreenshotOverlayEvent] = []
        controller.present(snapshot()) { events.append($0) }
        defer { controller.dismiss() }

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.panels.count, 2)
        XCTAssertEqual(controller.panels[0].frame, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(controller.panels[1].frame, CGRect(x: 200, y: -50, width: 300, height: 150))
        XCTAssertEqual(controller.panels[0].level, .screenSaver)
        XCTAssertTrue(controller.panels[0].collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controller.panels[0].collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(controller.panels[0].canBecomeKey)
        XCTAssertFalse(controller.panels[0].canBecomeMain)
        XCTAssertEqual(controller.viewUnderPointer()?.display.id, 2)
        XCTAssertEqual(controller.views[1].selection.pointer, CGPoint(x: 50, y: 20), "The loupe shows at once")

        // The shortcut again: the display under the pointer.
        controller.selectFullScreen()
        XCTAssertEqual(controller.views[1].selection.rect, CGRect(x: 0, y: 0, width: 300, height: 150))

        // Pressing on the other display moves the selection there.
        pointer = CGPoint(x: 10, y: 10)
        let first = controller.views[0]
        first.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        first.mouseDragged(to: CGPoint(x: 60, y: 40))
        first.mouseUp(at: CGPoint(x: 60, y: 40))
        XCTAssertNil(controller.views[1].selection.rect)
        controller.selectFullScreen()
        XCTAssertEqual(first.selection.rect, CGRect(x: 0, y: 0, width: 200, height: 100),
                       "The display that has the selection")

        controller.views[1].selectAll()
        controller.views[1].handleKeyDown(Key.returnKey, modifiers: [])
        controller.views[1].pointerMoved(to: CGPoint(x: 5, y: 5))
        controller.views[1].clearSelection()
        controller.views[1].pointerMoved(to: CGPoint(x: 5, y: 5))
        controller.views[1].handleFlagsChanged(.shift)
        controller.views[1].handleKeyDown(Key.escape, modifiers: [])

        XCTAssertEqual(events, [
            .committed, .committed, .committed, .committed,
            .finish(.copy, displayID: 2, rect: CGRect(x: 200, y: 0, width: 300, height: 150)),
            .colorPicked("#000000"), .cancelled
        ])
    }

    func testDismissClosesEverythingAndStopsEvents() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        var events: [ScreenshotOverlayEvent] = []
        controller.present(snapshot()) { events.append($0) }
        let panels = controller.panels
        let view = controller.views[0]

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(controller.views.isEmpty)
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible && $0.contentView == nil })
        view.handleKeyDown(Key.escape, modifiers: [])
        XCTAssertTrue(events.isEmpty)
        controller.selectFullScreen()
        controller.dismiss()
    }

    func testPresentingAgainReplacesTheOldPanels() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        controller.present(snapshot()) { _ in }
        let old = controller.panels
        controller.present(snapshot()) { _ in }
        defer { controller.dismiss() }

        XCTAssertEqual(controller.panels.count, 2)
        XCTAssertTrue(old.allSatisfy { !$0.isVisible })
    }

    // MARK: Toast and guide

    func testToastContent() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/Shot.png")
        XCTAssertEqual(ScreenshotToastController.content(for: .copied).message, L("screenshot.toast.copied"))
        let saved = ScreenshotToastController.content(for: .saved(url))
        XCTAssertEqual(saved.message, L("screenshot.toast.saved", "Desktop"))
        XCTAssertEqual(saved.revealURL, url)
        let fallback = ScreenshotToastController.content(for: .savedAsCopy(reason: "disk full"))
        XCTAssertTrue(fallback.isError)
        XCTAssertTrue(fallback.message.contains("disk full"))
        XCTAssertTrue(ScreenshotToastController.content(for: .colorCopied("#ABCDEF")).message.contains("#ABCDEF"))
        XCTAssertEqual(ScreenshotToastController.content(for: .busy).message, L("screenshot.toast.busy"))
        XCTAssertTrue(ScreenshotToastController.content(for: .failed).isError)
    }

    func testToastShowsAndHides() throws {
        var revealed: [URL] = []
        let toast = ScreenshotToastController { revealed.append($0) }
        let url = URL(fileURLWithPath: "/tmp/Shot.png")

        toast.show(.saved(url))
        let panel = try XCTUnwrap(toast.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.screenSaver.rawValue)
        XCTAssertEqual(toast.content?.revealURL, url)

        toast.show(.copied)
        XCTAssertTrue(toast.panel === panel, "One panel, reused")
        toast.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(toast.content)

        let view = ScreenshotToastView(content: ScreenshotToastController.content(for: .saved(url))) {}
        XCTAssertGreaterThan(NSHostingView(rootView: view).fittingSize.width, 0)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testGuideShowsRechecksAndCloses() throws {
        let guide = ScreenshotPermissionGuideController()
        var granted = false
        var calls: [String] = []
        guide.show(actions: .init(openSettings: { calls.append("settings") },
                                  recheck: { calls.append("recheck"); return granted },
                                  restart: { calls.append("restart") },
                                  later: { calls.append("later") }))
        defer { guide.dismiss() }

        XCTAssertTrue(guide.isVisible)
        XCTAssertEqual(guide.window?.title, L("screenshot.permission.title"))
        guide.recheck()
        XCTAssertTrue(guide.model.stillMissing)
        granted = true
        guide.recheck()
        XCTAssertFalse(guide.model.stillMissing)
        XCTAssertEqual(calls, ["recheck", "recheck"])

        // Showing again starts fresh and reuses the window.
        let window = guide.window
        guide.model.stillMissing = true
        guide.show(actions: .init(openSettings: {}, recheck: { false }, restart: {}, later: {}))
        XCTAssertFalse(guide.model.stillMissing)
        XCTAssertTrue(guide.window === window)

        guide.dismiss()
        XCTAssertFalse(guide.isVisible)
        guide.recheck()
        XCTAssertFalse(guide.model.stillMissing, "No actions after dismissal")

        let view = ScreenshotPermissionGuideView(model: .init(), openSettings: {}, recheck: {}, restart: {},
                                                 later: {})
        XCTAssertGreaterThan(NSHostingView(rootView: view).fittingSize.height, 0)
    }

    func testRelaunchCommandPassesThePathAsAnArgument() {
        let command = ScreenshotAppRelauncher.command(bundlePath: "/Applications/Type \"flux\".app")

        XCTAssertEqual(command.executable.path, "/bin/sh")
        XCTAssertEqual(command.arguments.last, "/Applications/Type \"flux\".app")
        XCTAssertFalse(command.arguments[1].contains("Applications"))
    }

    func testWindowsAreOrderedFrontToBack() {
        let windows = (1 ... 4).map { ScreenCaptureTestSupport.window(CGWindowID($0), processID: 1) }

        let ordered = ScreenCaptureContent.ordered(windows, frontToBack: [3, 1, 3])

        XCTAssertEqual(ordered.map(\.id), [3, 1, 2, 4], "Unknown windows keep their order at the back")
    }
}
