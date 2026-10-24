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

    func testFramingDefersEditorWorkUntilTheRegionIsCommitted() throws {
        let (view, _) = makeView()
        let canvas = try XCTUnwrap(view.subviews.first { $0 is ScreenshotAnnotationCanvasView }
            as? ScreenshotAnnotationCanvasView)
        view.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 60, y: 40))
        view.mouseDragged(to: CGPoint(x: 100, y: 70))

        XCTAssertNil(view.backgroundRemoval.region)
        XCTAssertNil(canvas.model.crop, "An empty editor does not redraw while framing")
        XCTAssertNil(view.toolbar)

        view.mouseUp(at: CGPoint(x: 100, y: 70))
        let rect = CGRect(x: 10, y: 10, width: 90, height: 60)
        XCTAssertEqual(view.backgroundRemoval.region, rect)
        XCTAssertEqual(canvas.model.crop, rect)
        XCTAssertEqual(view.toolbar?.isHidden, false)

        view.mouseDown(at: CGPoint(x: 30, y: 30), clickCount: 1)
        XCTAssertEqual(view.backgroundRemoval.region, rect, "Pressing without moving keeps the committed preview")
        view.mouseDragged(to: CGPoint(x: 40, y: 40))
        XCTAssertNil(view.backgroundRemoval.region, "A changed region retires the old preview")
        view.mouseUp(at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(view.backgroundRemoval.region, rect.offsetBy(dx: 10, dy: 10))
    }

    func testDimLayersCoverOnlyOutsideTheSelectedRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let hole = CGRect(x: 40, y: 20, width: 100, height: 50)
        let frames = ScreenshotOverlayView.dimFrames(in: bounds, around: hole)

        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height },
                       bounds.width * bounds.height - hole.width * hole.height)
        for point in [CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50), CGPoint(x: 90, y: 10),
                      CGPoint(x: 90, y: 90)] {
            XCTAssertEqual(frames.filter { $0.contains(point) }.count, 1)
        }
        XCTAssertFalse(frames.contains { $0.contains(CGPoint(x: 90, y: 45)) })
        XCTAssertEqual(ScreenshotOverlayView.dimFrames(in: bounds, around: nil).first, bounds)
        XCTAssertEqual(ScreenshotOverlayView.dimFrames(in: bounds, around: bounds).reduce(0) {
            $0 + $1.width * $1.height
        }, 0)
    }

    func testFramingTimerDrawsLatestPointAndMouseUpFlushesImmediately() throws {
        let (view, _) = makeView()
        view.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 40, y: 40))
        view.mouseDragged(to: CGPoint(x: 80, y: 60))

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try chrome(of: view).model.selection, CGRect(x: 10, y: 10, width: 70, height: 50))

        view.mouseDragged(to: CGPoint(x: 100, y: 70))
        view.mouseUp(at: CGPoint(x: 100, y: 70))
        XCTAssertEqual(try chrome(of: view).model.selection, CGRect(x: 10, y: 10, width: 90, height: 60))
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
        XCTAssertTrue(view.handleKeyDown(Key.space, modifiers: []))
        XCTAssertTrue(view.handleKeyDown(Key.escape, modifiers: []))
        let all = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(events(), [.committed, .finish(.copy, all), .finish(.copy, all), .finish(.copy, all),
                                  .finish(.save, all), .finish(.save, all), .cancelled])

        XCTAssertTrue(view.handleKeyDown(Key.keyC, modifiers: []), "Plain C picks the callout")
        XCTAssertEqual(view.editor.tool, .callout)
        XCTAssertTrue(view.handleKeyDown(Key.keyS, modifiers: []), "Plain S starts a scrolling capture")
        XCTAssertEqual(events().last, .scroll(all))
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

    func testSpaceSavesOnlyAfterTheRegionIsCommitted() {
        let (view, events) = makeView()
        XCTAssertTrue(view.handleKeyDown(Key.space, modifiers: []))
        XCTAssertTrue(view.spaceHeld)
        XCTAssertTrue(events().isEmpty)
        view.handleKeyUp(Key.space)

        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 110, y: 60)
        view.mouseDown(at: start, clickCount: 1)
        view.mouseDragged(to: end)
        XCTAssertTrue(view.handleKeyDown(Key.space, modifiers: []))
        XCTAssertTrue(view.spaceHeld)
        XCTAssertTrue(events().isEmpty)
        view.handleKeyUp(Key.space)
        view.mouseUp(at: end)

        XCTAssertFalse(view.handleKeyDown(Key.space, modifiers: .shift))
        XCTAssertTrue(view.handleKeyDown(Key.space, modifiers: [], isRepeat: true))
        XCTAssertEqual(events(), [.committed])
        XCTAssertTrue(view.handleKeyDown(Key.space, modifiers: []))
        XCTAssertEqual(events(), [.committed, .finish(.save, CGRect(x: 10, y: 10, width: 100, height: 50))])
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

    func testShortcutShiftDoesNotCopyColorUntilPressedAgainAlone() {
        let view = ScreenshotOverlayView(display: Self.display(), windows: [],
                                         initialModifierFlags: [.command, .shift])
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        view.pointerMoved(to: CGPoint(x: 30, y: 30))

        view.handleFlagsChanged([.command, .shift])
        view.handleFlagsChanged(.shift)
        view.handleFlagsChanged([])
        view.handleFlagsChanged([.command, .shift])
        view.handleFlagsChanged(.shift)
        XCTAssertTrue(events.isEmpty, "The shortcut's Shift must not pick a color")

        view.handleFlagsChanged([])
        view.handleFlagsChanged(.shift)
        XCTAssertEqual(events, [.colorPicked("#000000")])
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

        XCTAssertEqual(events(), [.committed, .finish(.save, CGRect(x: 20, y: 20, width: 100, height: 50)),
                                  .finish(.copy, CGRect(x: 20, y: 20, width: 100, height: 50)), .cancelled])
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
        let selectionEdge = try XCTUnwrap(bitmap.colorAt(x: Int(19 * scale), y: Int(100 * scale)))
        XCTAssertGreaterThan(selectionEdge.redComponent, 0.9)
        XCTAssertGreaterThan(selectionEdge.greenComponent, 0.9)
        XCTAssertGreaterThan(selectionEdge.blueComponent, 0.9)
        let guide = try XCTUnwrap(bitmap.colorAt(x: Int(25 * scale), y: Int(100 * scale)))
        XCTAssertGreaterThan(guide.redComponent, 0.9)
        XCTAssertGreaterThan(guide.greenComponent, 0.9)
        XCTAssertGreaterThan(guide.blueComponent, 0.9)
        let handle = try XCTUnwrap(bitmap.colorAt(x: Int(23 * scale), y: Int(140 * scale)))
        XCTAssertEqual(handle.redComponent, handle.greenComponent, accuracy: 0.02)
        XCTAssertEqual(handle.greenComponent, handle.blueComponent, accuracy: 0.02)
        let loupeCenter = try XCTUnwrap(bitmap.colorAt(x: Int(170 * scale), y: Int(165 * scale)))
        XCTAssertGreaterThan(loupeCenter.redComponent, 0.9)
        XCTAssertGreaterThan(loupeCenter.greenComponent, 0.9)
        XCTAssertGreaterThan(loupeCenter.blueComponent, 0.9)
        // The loupe's dark body is drawn where it was placed.
        XCTAssertGreaterThan(bitmap.colorAt(x: Int(200 * scale), y: Int(130 * scale))?.alphaComponent ?? 0, 0.5)

        chrome.model = .init(hovered: CGRect(x: 10, y: 10, width: 50, height: 50), sizeLabel: "50 × 50")
        let hovered = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
        chrome.cacheDisplay(in: chrome.bounds, to: hovered)
        // The hovered window's outline, and nothing in the middle of it.
        let hoveredEdge = try XCTUnwrap(hovered.colorAt(x: Int(11 * scale), y: Int(35 * scale)))
        XCTAssertGreaterThan(hoveredEdge.redComponent, 0.9)
        XCTAssertGreaterThan(hoveredEdge.greenComponent, 0.9)
        XCTAssertGreaterThan(hoveredEdge.blueComponent, 0.9)
        XCTAssertEqual(hovered.colorAt(x: Int(35 * scale), y: Int(50 * scale))?.alphaComponent ?? 1, 0)
    }

    func testChromeInvalidatesOnlyChangedFramingParts() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let old = ScreenshotOverlayChromeView.Model(selection: CGRect(x: 100, y: 100, width: 200, height: 120),
                                                    sizeLabel: "200 × 120", pointer: CGPoint(x: 300, y: 220))
        let new = ScreenshotOverlayChromeView.Model(selection: CGRect(x: 100, y: 100, width: 250, height: 160),
                                                    sizeLabel: "250 × 160", pointer: CGPoint(x: 350, y: 260))
        let rects = ScreenshotOverlayChromeView.invalidationRects(from: old, to: new, in: bounds)

        XCTAssertFalse(rects.isEmpty)
        XCTAssertTrue(rects.allSatisfy { $0.width < bounds.width || $0.height < bounds.height },
                      "Dragging never invalidates the whole display")
        XCTAssertLessThan(rects.reduce(0) { $0 + $1.width * $1.height }, bounds.width * bounds.height / 2,
                          "Only outlines and narrow guide strips need repainting")
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 300, y: 220)) }, "Old frame is erased")
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 350, y: 260)) }, "New frame is drawn")
        XCTAssertTrue(ScreenshotOverlayChromeView.invalidationRects(from: new, to: new, in: bounds).isEmpty)
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

    func testSystemDisplayPrewarmDoesNotPresentOrTakeFocus() {
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        let controller = ScreenshotOverlayController()
        controller.prewarm()
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(controller.panels.isEmpty && controller.views.isEmpty)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        controller.prewarm(displays: [])
    }

    func testPrewarmCreatesOnlyHiddenEmptyWindowsAndFirstCaptureReusesThem() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        let displays = snapshot().displays.map { ScreenCaptureContent.Display(id: $0.id, frame: $0.frame, scale: $0.scale) }
        let prepared = controller.prewarm(displays: displays)
        XCTAssertEqual(prepared.count, 2)
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(controller.panels.isEmpty && controller.views.isEmpty)
        XCTAssertTrue(prepared.allSatisfy { !$0.isVisible && !$0.isKeyWindow && $0.contentView == nil })
        XCTAssertTrue(controller.prewarm(displays: displays)[0] === prepared[0])
        controller.present(snapshot()) { _ in }
        defer { controller.dismiss() }
        XCTAssertTrue(controller.panels[0] === prepared[0])
        XCTAssertTrue(controller.panels[1] === prepared[1])
        XCTAssertTrue(controller.prewarm(displays: []).isEmpty, "Prewarm must not disturb a live capture")
        XCTAssertTrue(controller.panels.allSatisfy(\.isVisible))
    }

    func testPrewarmEvictsRemovedDisplaysAndRebuildsChangedGeometry() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        let displays = snapshot().displays.map { ScreenCaptureContent.Display(id: $0.id, frame: $0.frame, scale: $0.scale) }
        let original = controller.prewarm(displays: displays)
        var changed = displays[0]
        changed.frame.size.width += 10
        changed.scale = 1
        let rebuilt = controller.prewarm(displays: [changed])
        XCTAssertFalse(rebuilt[0] === original[0])
        let restored = controller.prewarm(displays: displays)
        XCTAssertFalse(restored[1] === original[1])
        XCTAssertTrue(restored.allSatisfy { !$0.isVisible && $0.contentView == nil })
        controller.prewarm(displays: [])
    }

    func testControllerReusesOnlyNativePanelsAndRetiresOldCaptureCallbacks() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        controller.present(snapshot()) { _ in }
        let originalPanels = controller.panels, originalViews = controller.views
        originalViews[0].selectAll()
        XCTAssertNotNil(originalViews[0].selection.rect)
        controller.dismiss()
        XCTAssertTrue(originalPanels.allSatisfy { !$0.isVisible && $0.contentView == nil })
        XCTAssertTrue(originalViews.allSatisfy { $0.onEvent == nil && $0.onActivate == nil })
        XCTAssertTrue(originalViews.allSatisfy { $0.layer?.sublayers?.first?.contents == nil })
        let diagnostics = ShortcutLatencyEventCollector(), trace = diagnosticTestTrace(.screenshot)
        ShortcutLatency.$eventSink.withValue(diagnostics.sink) {
            ShortcutLatency.$current.withValue(trace) { controller.present(snapshot()) { _ in } }
        }
        defer { controller.dismiss() }
        XCTAssertTrue(controller.panels[0] === originalPanels[0])
        XCTAssertTrue(controller.panels[1] === originalPanels[1])
        XCTAssertFalse(controller.views[0] === originalViews[0])
        XCTAssertNil(controller.views[0].selection.rect)
        XCTAssertEqual(diagnostics.events.filter { $0.stage == .windowCached }.map(\.itemIndex), [1, 2])
        XCTAssertFalse(diagnostics.stages.contains(.windowUncached))
    }

    func testControllerRebuildsChangedDisplaysAndEvictsDisconnectedPanels() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        controller.present(snapshot()) { _ in }
        let original = controller.panels
        let resized = ScreenSnapshot(displays: [Self.display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)], windows: [])
        controller.present(resized) { _ in }
        XCTAssertEqual(controller.panels.count, 1)
        XCTAssertFalse(controller.panels[0] === original[0])
        XCTAssertFalse(original[0].isVisible)
        XCTAssertFalse(original[1].isVisible)
        controller.present(snapshot()) { _ in }
        XCTAssertFalse(controller.panels[1] === original[1], "A disconnected display must not stay in the pool")
        controller.dismiss()
    }

    func testControllerShowsOnePanelPerDisplayAndConvertsRegions() throws {
        var pointer = CGPoint(x: 250, y: 20)
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { pointer })
        var events: [ScreenshotOverlayEvent] = []
        let diagnostics = ShortcutLatencyEventCollector(), trace = diagnosticTestTrace(.screenshot)
        ShortcutLatency.$eventSink.withValue(diagnostics.sink) {
            ShortcutLatency.$current.withValue(trace) { controller.present(snapshot()) { events.append($0) } }
        }
        defer { controller.dismiss() }
        for stage in [ShortcutLatencyStage.displayViewStarted, .displayViewFinished, .displayPanelStarted,
                      .displayPanelFinished, .displayShowStarted, .displayShowFinished] {
            let events = diagnostics.events.filter { $0.stage == stage }
            XCTAssertEqual(events.map(\.itemIndex), [1, 2])
            XCTAssertTrue(events.allSatisfy { $0.itemCount == 2 && $0.trace == trace })
        }
        XCTAssertEqual(diagnostics.stages.prefix(2), [.overlayStarted, .oldOverlayRetired])
        XCTAssertEqual(diagnostics.stages.suffix(8), [.focusStarted, .windowKeyStarted, .windowKeyFinished, .focusFinished, .pointerUpdateStarted,
                                                      .pointerUpdateFinished, .overlayFinished, .windowOrdered])

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

    func testControllerPreservesHeldShortcutModifiersAcrossOverlayPresentation() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero },
                                                     modifierFlags: { [.command, .shift] })
        var events: [ScreenshotOverlayEvent] = []
        controller.present(snapshot()) { events.append($0) }
        defer { controller.dismiss() }

        let view = controller.views[0]
        view.handleFlagsChanged(.shift)
        XCTAssertTrue(events.isEmpty)
        view.handleFlagsChanged([])
        view.handleFlagsChanged(.shift)
        XCTAssertEqual(events, [.colorPicked("#000000")])
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

    func testPresentingAgainReplacesOldContentAndReusesThePanels() {
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero })
        var oldEvents = 0, newEvents = 0
        controller.present(snapshot()) { _ in oldEvents += 1 }
        let old = controller.panels, oldViews = controller.views
        controller.present(snapshot()) { _ in newEvents += 1 }
        defer { controller.dismiss() }

        XCTAssertEqual(controller.panels.count, 2)
        XCTAssertTrue(controller.panels[0] === old[0] && controller.panels[1] === old[1])
        XCTAssertTrue(old.allSatisfy(\.isVisible))
        XCTAssertFalse(controller.views[0] === oldViews[0])
        oldViews[0].handleKeyDown(Key.escape, modifiers: [])
        XCTAssertEqual(oldEvents, 0)
        XCTAssertEqual(newEvents, 0)
        controller.views[0].handleKeyDown(Key.escape, modifiers: [])
        XCTAssertEqual(newEvents, 1)
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
        XCTAssertEqual(ScreenshotToastController.content(for: .scrollLimitReached).message,
                       L("screenshot.toast.scrollLimit"))
        XCTAssertFalse(ScreenshotToastController.content(for: .scrollLimitReached).isError)
        XCTAssertEqual(ScreenshotToastController.content(for: .scrollUnavailable).message,
                       L("screenshot.toast.scrollUnavailable"))
        XCTAssertTrue(ScreenshotToastController.content(for: .scrollInterrupted).isError)
        XCTAssertEqual(ScreenshotToastController.content(for: .scrollInterrupted).message,
                       L("screenshot.toast.scrollInterrupted"))
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

        guide.openSettings()
        XCTAssertFalse(guide.isVisible)
        XCTAssertEqual(calls.last, "settings")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(guide.isVisible)

        // Showing again starts fresh and reuses the window.
        let window = guide.window
        guide.model.stillMissing = true
        guide.show(actions: .init(openSettings: {}, recheck: { false }, restart: {}, later: {}))
        XCTAssertFalse(guide.model.stillMissing)
        XCTAssertTrue(guide.window === window)

        guide.openSettings()
        guide.dismiss()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
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
