import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// The editing half of the overlay: tools, keys, toolbar and text, wired to the real view.
@MainActor
final class ScreenshotEditorOverlayTests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key

    private final class Measurer: ScreenshotTextHeightMeasuring {
        var height: CGFloat?
        private(set) var measured: [CGSize] = []

        func tallestLineHeight(in image: CGImage) -> CGFloat? {
            measured.append(CGSize(width: image.width, height: image.height))
            return height
        }
    }

    private func makeView(width: CGFloat = 400, height: CGFloat = 300, scale: CGFloat = 2,
                          measurer: Measurer? = nil) -> (ScreenshotOverlayView,
                                                         () -> [ScreenshotOverlayView.LocalEvent]) {
        let display = ScreenSnapshot.Display(
            id: 1, frame: CGRect(x: 0, y: 0, width: width, height: height), scale: scale,
            image: ScreenCaptureTestSupport.image(width: Int(width * scale), height: Int(height * scale))
        )
        let view = ScreenshotOverlayView(display: display, windows: [], textMeasurer: measurer)
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        return (view, { events })
    }

    private func frame(_ view: ScreenshotOverlayView, from start: CGPoint, to end: CGPoint) {
        view.mouseDown(at: start, clickCount: 1)
        view.mouseDragged(to: end)
        view.mouseUp(at: end)
    }

    private func drag(_ view: ScreenshotOverlayView, from start: CGPoint, to end: CGPoint, shift: Bool = false) {
        view.mouseDown(at: start, clickCount: 1, shift: shift)
        view.mouseDragged(to: end, shift: shift)
        view.mouseUp(at: end, shift: shift)
    }

    func testDrawnAnnotationsTravelWithTheFinishedRegion() {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200))
        let region = CGRect(x: 50, y: 50, width: 200, height: 150)

        XCTAssertTrue(view.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: []))
        drag(view, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 120, y: 100))
        XCTAssertEqual(view.selection.rect, region, "Drawing leaves the region alone")
        XCTAssertTrue(view.handleKeyDown(Key.returnKey, modifiers: []))

        let box = ScreenshotAnnotation.Kind.rect(CGRect(x: 60, y: 60, width: 60, height: 40))
        guard case let .finish(.copy, rect, annotations)? = events().last else { return XCTFail("No finish") }
        XCTAssertEqual(rect, region)
        XCTAssertEqual(annotations.map(\.kind), [box])
    }

    func testUndoRedoDeleteAndArrowsOnTheSelection() {
        let (view, _) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200))
        view.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.editor.document.annotations.count, 1)

        XCTAssertTrue(view.handleKeyDown(Key.keyZ, modifiers: .command))
        XCTAssertTrue(view.editor.document.isEmpty)
        XCTAssertTrue(view.handleKeyDown(Key.keyZ, modifiers: [.command, .shift]))
        XCTAssertEqual(view.editor.document.annotations.count, 1)

        // Select it, move it with the arrows, then delete it.
        view.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        view.mouseUp(at: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(view.editor.selected)
        XCTAssertTrue(view.handleKeyDown(Key.arrowRight, modifiers: .shift))
        XCTAssertEqual(view.editor.selected?.kind, .counter(center: CGPoint(x: 110, y: 100)))
        XCTAssertEqual(view.selection.rect, CGRect(x: 50, y: 50, width: 200, height: 150), "Not the region")
        XCTAssertTrue(view.handleKeyDown(Key.delete, modifiers: []))
        XCTAssertTrue(view.editor.document.isEmpty)
        XCTAssertTrue(view.handleKeyDown(Key.forwardDelete, modifiers: []), "Nothing left, still consumed")

        // With nothing selected, arrows move the region again.
        XCTAssertTrue(view.handleKeyDown(Key.arrowRight, modifiers: []))
        XCTAssertEqual(view.selection.rect?.minX, 51)
    }

    func testEditingKeysWaitForARegion() {
        let (view, _) = makeView()
        XCTAssertFalse(view.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: []))
        XCTAssertFalse(view.handleKeyDown(Key.keyZ, modifiers: .command))
        XCTAssertNil(view.editor.tool)
    }

    func testOnceMarkingStartsAPressOutsideKeepsTheRegion() {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        view.handleKeyDown(ScreenshotAnnotationTool.arrow.keyCode, modifiers: [])
        XCTAssertTrue(view.isAnnotating)

        drag(view, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 350, y: 280))
        XCTAssertEqual(view.selection.rect, CGRect(x: 50, y: 50, width: 100, height: 100))
        XCTAssertTrue(view.editor.document.isEmpty, "Nothing is drawn outside the region")
        XCTAssertEqual(events(), [.committed])

        // The region's own handles still crop.
        drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 180, y: 170))
        XCTAssertEqual(view.selection.rect, CGRect(x: 50, y: 50, width: 130, height: 120))
    }

    func testWithoutAToolTheRegionStillMovesAndDoubleClickCopiesWithTheMarks() {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        view.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        drag(view, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 70, y: 70))
        view.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        XCTAssertNil(view.editor.tool)

        drag(view, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 130, y: 120))
        XCTAssertEqual(view.selection.rect?.minX, 60, "No tool: dragging inside moves the region")

        view.mouseDown(at: CGPoint(x: 120, y: 120), clickCount: 2)
        guard case let .finish(.copy, _, annotations)? = events().last else { return XCTFail("No finish") }
        XCTAssertEqual(annotations.count, 1)
    }

    func testToolbarFollowsTheEditorAndItsButtonsAct() throws {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 150))
        let toolbar = try XCTUnwrap(view.toolbar)
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertGreaterThan(toolbar.frame.minY, 150 - ScreenshotOverlayView.toolbarShadowInset,
                             "Below the region")
        XCTAssertFalse(view.toolbarModel.state.showsOptions)
        let oneRow = toolbar.frame.height

        view.toolbarModel.perform(.tool(.mosaic))
        XCTAssertGreaterThan(toolbar.frame.height, oneRow, "The options row shows at once")
        XCTAssertEqual(view.editor.tool, .mosaic)
        XCTAssertTrue(view.toolbarModel.state.showsOptions)
        XCTAssertTrue(view.toolbarModel.state.showsMosaicOptions)
        view.toolbarModel.perform(.mosaicShape(.brush))
        view.toolbarModel.perform(.mosaicEffect(.blur))
        view.toolbarModel.perform(.mosaicStrength(.low))
        XCTAssertEqual(view.toolbarModel.state.mosaicShape, .brush)
        XCTAssertEqual(view.toolbarModel.state.mosaicEffect, .blur)
        XCTAssertEqual(view.toolbarModel.state.mosaicStrength, .low)

        view.toolbarModel.perform(.tool(.pen))
        view.toolbarModel.perform(.color(.green))
        view.toolbarModel.perform(.width(.thick))
        XCTAssertEqual(view.toolbarModel.state.style, ScreenshotAnnotationStyle(color: .green, width: .thick))
        XCTAssertFalse(view.toolbarModel.state.canUndo)
        drag(view, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 90, y: 90))
        XCTAssertTrue(view.toolbarModel.state.canUndo)
        view.toolbarModel.perform(.undo)
        XCTAssertTrue(view.toolbarModel.state.canRedo)
        view.toolbarModel.perform(.redo)
        XCTAssertEqual(view.editor.document.annotations.count, 1)

        view.toolbarModel.perform(.copy)
        view.toolbarModel.perform(.save)
        view.toolbarModel.perform(.cancel)
        let region = CGRect(x: 50, y: 50, width: 200, height: 100)
        let marks = view.editor.document.annotations
        XCTAssertEqual(events(), [.committed, .finish(.copy, region, marks), .finish(.save, region, marks),
                                  .cancelled])

        // Hidden while the region is being resized.
        view.mouseDown(at: CGPoint(x: 250, y: 150), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 300, y: 200))
        XCTAssertTrue(toolbar.isHidden)
        view.mouseUp(at: CGPoint(x: 300, y: 200))
        XCTAssertFalse(toolbar.isHidden)
    }

    func testToolbarRendersBothRows() {
        func size(_ state: ScreenshotEditorToolbarModel.State) -> CGSize {
            NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }).fittingSize
        }
        var state = ScreenshotEditorToolbarModel.State()
        let oneRow = size(state)
        XCTAssertGreaterThan(oneRow.width, 300)
        XCTAssertEqual(oneRow.height, ScreenshotEditorToolbar.barHeight, accuracy: 1)

        state.showsOptions = true
        let twoRows = size(state)
        XCTAssertGreaterThan(twoRows.height, oneRow.height + ScreenshotEditorToolbar.rowSpacing)
        state.showsMosaicOptions = true
        state.mosaicShape = .brush
        XCTAssertGreaterThan(size(state).height, oneRow.height)

        for tool in ScreenshotAnnotationTool.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: tool).isEmpty)
            XCTAssertTrue(ScreenshotEditorToolbarModel.help(for: tool).hasSuffix(tool.shortcut))
            XCTAssertNotEqual(L("screenshot.tool.\(tool.rawValue)"), "screenshot.tool.\(tool.rawValue)")
        }
        for effect in ScreenshotMosaic.Effect.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: effect).isEmpty)
        }
        for shape in ScreenshotAnnotationEditor.MosaicShape.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: shape).isEmpty)
        }
    }

    func testTypingTextThroughTheField() throws {
        let (view, _) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
        view.handleKeyDown(ScreenshotAnnotationTool.text.keyCode, modifiers: [])

        view.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        view.mouseUp(at: CGPoint(x: 100, y: 100))
        let field = try XCTUnwrap(view.textField)
        XCTAssertEqual(field.frame.minX, 100 - ScreenshotOverlayView.textFieldInset)
        XCTAssertEqual(field.frame.minY, 100)
        let emptyWidth = field.frame.width
        field.stringValue = "Peak in September"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertGreaterThan(field.frame.width, emptyWidth, "The field grows with the text")

        // Return commits.
        XCTAssertTrue(view.control(field, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertNil(view.textField)
        XCTAssertNil(field.superview)
        XCTAssertEqual(view.editor.document.annotations.map(\.kind),
                       [.text(origin: CGPoint(x: 100, y: 100), "Peak in September", fontSize: 18)])

        // Double-click edits it; esc keeps it as it was.
        view.mouseDown(at: CGPoint(x: 105, y: 105), clickCount: 2)
        let editing = try XCTUnwrap(view.textField)
        XCTAssertEqual(editing.stringValue, "Peak in September")
        editing.stringValue = "Changed"
        XCTAssertTrue(view.control(editing, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(view.textField)
        XCTAssertEqual(view.editor.document.annotations.count, 1)
        guard case let .text(_, text, _) = view.editor.document.annotations[0].kind else { return XCTFail("No text") }
        XCTAssertEqual(text, "Peak in September")
        XCTAssertFalse(view.control(editing, textView: NSTextView(),
                                    doCommandBy: #selector(NSResponder.moveLeft(_:))))

        // A new press commits whatever is being typed.
        view.mouseDown(at: CGPoint(x: 200, y: 200), clickCount: 1)
        try XCTUnwrap(view.textField).stringValue = "Second"
        view.mouseDown(at: CGPoint(x: 300, y: 220), clickCount: 1)
        XCTAssertEqual(view.editor.document.annotations.count, 2)
        view.cancelTextEditing()
        view.cancelTextEditing()
        view.endTextEditing()
        XCTAssertEqual(view.editor.document.annotations.count, 2)
    }

    func testFinishingCommitsTheTextBeingTyped() throws {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
        view.toolbarModel.perform(.tool(.text))
        view.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        try XCTUnwrap(view.textField).stringValue = "Note"
        let copyKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                     timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                                                     charactersIgnoringModifiers: "c", isARepeat: false,
                                                     keyCode: Key.keyC))
        XCTAssertFalse(view.performKeyEquivalent(with: copyKey), "⌘C copies the typed text, not the screenshot")
        XCTAssertEqual(events(), [.committed])

        view.handleKeyDown(Key.keyC, modifiers: .command)

        guard case let .finish(.copy, _, annotations)? = events().last else { return XCTFail("No finish") }
        XCTAssertEqual(annotations.count, 1)
    }

    func testMosaicsAreSizedToTheTextUnderThem() {
        let measurer = Measurer()
        measurer.height = 40
        let (view, _) = makeView(scale: 2, measurer: measurer)
        frame(view, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 200))
        view.handleKeyDown(ScreenshotAnnotationTool.mosaic.keyCode, modifiers: [])

        // Half of it hangs outside the region; only the part inside is measured.
        drag(view, from: CGPoint(x: 150, y: 50), to: CGPoint(x: 250, y: 80))

        XCTAssertEqual(measurer.measured, [CGSize(width: 100, height: 60)])
        XCTAssertEqual(view.editor.document.annotations.first?.mosaic?.textHeight, 20, "40 px on a 2× display")

        measurer.height = nil
        drag(view, from: CGPoint(x: 20, y: 120), to: CGPoint(x: 60, y: 160))
        XCTAssertNil(view.editor.document.annotations.last?.mosaic?.textHeight)

        let (unmeasured, _) = makeView()
        frame(unmeasured, from: .zero, to: CGPoint(x: 200, y: 200))
        unmeasured.handleKeyDown(ScreenshotAnnotationTool.mosaic.keyCode, modifiers: [])
        drag(unmeasured, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
        XCTAssertNil(unmeasured.editor.document.annotations.first?.mosaic?.textHeight)
    }

    func testCursorFollowsWhatAPressWouldDo() {
        let (view, _) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200))
        view.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))

        view.pointerMoved(to: CGPoint(x: 100, y: 100))
        view.pointerMoved(to: CGPoint(x: 150, y: 150))
        view.handleKeyDown(ScreenshotAnnotationTool.text.keyCode, modifiers: [])
        view.pointerMoved(to: CGPoint(x: 150, y: 150))
        view.pointerMoved(to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(view.selection.pointer, CGPoint(x: 300, y: 250))
    }

    func testShiftOnRealEventsConstrainsTheShape() throws {
        let (view, _) = makeView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.contentView = view
        frame(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 390, y: 290))
        view.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: [])

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .shift, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        // Window coordinates grow upward: (20, 280) is (20, 20) in the view.
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 20, y: 280)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 120, y: 260)))
        view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 120, y: 260)))

        XCTAssertEqual(view.editor.document.annotations.first?.frame, CGRect(x: 20, y: 20, width: 100, height: 100))
    }

    func testControllerHandsOverAnnotationsInGlobalPoints() {
        let snapshot = ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 200, height: 100)),
            .init(id: 2, frame: CGRect(x: 200, y: 0, width: 300, height: 150), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 300, height: 150))
        ], windows: [])
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 150 }, pointerLocation: { .zero },
                                                     textMeasurer: Measurer())
        var events: [ScreenshotOverlayEvent] = []
        controller.present(snapshot) { events.append($0) }
        defer { controller.dismiss() }
        let view = controller.views[1]
        frame(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 110))
        view.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        view.handleKeyDown(Key.keyS, modifiers: .command)

        guard case let .finish(.save, displayID, rect, annotations)? = events.last else { return XCTFail("No finish") }
        XCTAssertEqual(displayID, 2)
        XCTAssertEqual(rect, CGRect(x: 210, y: 10, width: 100, height: 100))
        XCTAssertEqual(annotations.map(\.kind), [.counter(center: CGPoint(x: 250, y: 50))])
    }

    func testAnotherDisplayCannotTakeTheRegionWhileOneIsMarkedUp() {
        let snapshot = ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 200, height: 100)),
            .init(id: 2, frame: CGRect(x: 200, y: 0, width: 300, height: 150), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 300, height: 150))
        ], windows: [])
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 150 }, pointerLocation: { .zero })
        controller.present(snapshot) { _ in }
        defer { controller.dismiss() }
        let (first, second) = (controller.views[0], controller.views[1])
        frame(first, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 90))
        first.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: [])

        frame(second, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 90))
        second.selectAll()
        XCTAssertNil(second.selection.rect, "Ignored while the first display is marked up")
        XCTAssertEqual(first.selection.rect, CGRect(x: 10, y: 10, width: 100, height: 80))

        first.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: [])
        frame(second, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 90))
        XCTAssertNotNil(second.selection.rect, "With the tool put down and nothing drawn, it can move")
        XCTAssertNil(first.selection.rect)
    }

    func testTheToolbarsShadowMarginLetsPressesThrough() throws {
        let (view, _) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 150))
        let toolbar = try XCTUnwrap(view.toolbar)
        let inset = ScreenshotOverlayView.toolbarShadowInset

        XCTAssertNil(toolbar.hitTest(CGPoint(x: toolbar.frame.minX + inset / 2, y: toolbar.frame.midY)))
        let firstButton = CGPoint(x: toolbar.frame.minX + inset + 15, y: toolbar.frame.minY + inset + 15)
        XCTAssertNotNil(toolbar.hitTest(firstButton))
    }

    func testTheOptionsRowShowsTheSelectedMarksStyle() {
        let (view, _) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
        view.toolbarModel.perform(.tool(.mosaic))
        view.toolbarModel.perform(.mosaicShape(.brush))
        view.toolbarModel.perform(.mosaicEffect(.blur))
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100))
        view.toolbarModel.perform(.tool(.rect))
        view.toolbarModel.perform(.color(.green))
        drag(view, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 200, y: 220))
        view.toolbarModel.perform(.mosaicShape(.rect))
        view.toolbarModel.perform(.mosaicEffect(.solid))
        view.toolbarModel.perform(.color(.white))
        XCTAssertEqual(view.toolbarModel.state.style.color, .white)

        // Select the green box: the row shows green.
        view.mouseDown(at: CGPoint(x: 100, y: 180), clickCount: 1)
        view.mouseUp(at: CGPoint(x: 100, y: 180))
        XCTAssertEqual(view.toolbarModel.state.style.color, .green)

        // Select the blurred brush: the row shows its options.
        view.mouseDown(at: CGPoint(x: 150, y: 100), clickCount: 1)
        view.mouseUp(at: CGPoint(x: 150, y: 100))
        XCTAssertTrue(view.toolbarModel.state.showsMosaicOptions)
        XCTAssertEqual(view.toolbarModel.state.mosaicShape, .brush)
        XCTAssertEqual(view.toolbarModel.state.mosaicEffect, .blur)
    }
}
