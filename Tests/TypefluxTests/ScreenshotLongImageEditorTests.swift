import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotLongImageEditorTests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key

    private final class Measurer: ScreenshotTextHeightMeasuring {
        var height: CGFloat? = 30
        private(set) var measured: [CGSize] = []

        func tallestLineHeight(in image: CGImage) -> CGFloat? {
            measured.append(CGSize(width: image.width, height: image.height))
            return height
        }
    }

    /// A 2× long image of 300 × 2000 points.
    private func makeCanvas(width: Int = 600, height: Int = 4000, measurer: Measurer? = nil)
        -> (ScreenshotLongImageCanvas, () -> [ScreenshotLongImageCanvas.Event]) {
        let canvas = ScreenshotLongImageCanvas(image: ScreenCaptureTestSupport.image(width: width, height: height),
                                               scale: 2, textMeasurer: measurer)
        var events: [ScreenshotLongImageCanvas.Event] = []
        canvas.onEvent = { events.append($0) }
        return (canvas, { events })
    }

    private func drag(_ canvas: ScreenshotLongImageCanvas, from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(at: start, clickCount: 1)
        canvas.mouseDragged(to: end)
        canvas.mouseUp(at: end)
    }

    // MARK: Canvas

    func testTheCanvasIsTheImageInPointsAndMarksStayInImagePoints() {
        let (canvas, events) = makeCanvas()
        XCTAssertEqual(canvas.bounds, CGRect(x: 0, y: 0, width: 300, height: 2000))

        XCTAssertTrue(canvas.handleKeyDown(ScreenshotAnnotationTool.rect.keyCode, modifiers: []))
        drag(canvas, from: CGPoint(x: 20, y: 1500), to: CGPoint(x: 80, y: 1540))
        XCTAssertTrue(canvas.handleKeyDown(Key.returnKey, modifiers: []))

        let box = ScreenshotAnnotation.Kind.rect(CGRect(x: 20, y: 1500, width: 60, height: 40))
        guard case let .finish(.copy, marks)? = events().last else { return XCTFail("No finish") }
        XCTAssertEqual(marks.map(\.kind), [box])
    }

    func testKeysActOnTheLongImage() {
        let (canvas, events) = makeCanvas()
        canvas.handleKeyDown(ScreenshotAnnotationTool.counter.keyCode, modifiers: [])
        drag(canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(canvas.editor.document.annotations.count, 1)

        XCTAssertTrue(canvas.handleKeyDown(Key.keyZ, modifiers: .command))
        XCTAssertTrue(canvas.editor.document.isEmpty)
        XCTAssertTrue(canvas.handleKeyDown(Key.keyZ, modifiers: [.command, .shift]))
        canvas.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        canvas.mouseUp(at: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(canvas.editor.selected)
        XCTAssertTrue(canvas.handleKeyDown(Key.arrowDown, modifiers: []))
        XCTAssertEqual(canvas.editor.selected?.kind, .counter(center: CGPoint(x: 100, y: 101)))
        XCTAssertTrue(canvas.handleKeyDown(Key.delete, modifiers: []))
        XCTAssertTrue(canvas.editor.document.isEmpty)
        XCTAssertFalse(canvas.handleKeyDown(Key.delete, modifiers: .command))
        XCTAssertFalse(canvas.handleKeyDown(Key.arrowDown, modifiers: []), "Nothing selected to move")
        XCTAssertFalse(canvas.handleKeyDown(Key.keyA, modifiers: .command))

        canvas.handleKeyDown(Key.keyC, modifiers: .command)
        canvas.handleKeyDown(Key.keyS, modifiers: .command)
        canvas.handleKeyDown(Key.enter, modifiers: [])
        canvas.handleKeyDown(Key.escape, modifiers: [])
        XCTAssertEqual(events(), [.finish(.copy, []), .finish(.save, []), .finish(.copy, []), .cancelled])
    }

    func testZoomKeys() {
        let (canvas, events) = makeCanvas()
        XCTAssertTrue(canvas.handleKeyDown(24, modifiers: .command, characters: "="))
        XCTAssertTrue(canvas.handleKeyDown(27, modifiers: .command, characters: "-"))
        XCTAssertTrue(canvas.handleKeyDown(29, modifiers: .command, characters: "0"))
        XCTAssertTrue(canvas.handleKeyDown(69, modifiers: .command))
        XCTAssertFalse(canvas.handleKeyDown(24, modifiers: []), "Without ⌘ it is not a zoom")
        XCTAssertEqual(events(), [.zoom(1), .zoom(-1), .zoom(0), .zoom(1)])

        XCTAssertEqual(ScreenshotLongImageCanvas.zoomStep(keyCode: 0, characters: "+"), 1)
        XCTAssertEqual(ScreenshotLongImageCanvas.zoomStep(keyCode: 0, characters: "_"), -1)
        XCTAssertEqual(ScreenshotLongImageCanvas.zoomStep(keyCode: 78, characters: nil), -1)
        XCTAssertEqual(ScreenshotLongImageCanvas.zoomStep(keyCode: 82, characters: nil), 0)
        XCTAssertNil(ScreenshotLongImageCanvas.zoomStep(keyCode: 0, characters: "a"))
    }

    func testRealKeyEventsReachTheHandlers() throws {
        let (canvas, events) = makeCanvas()
        let zoomIn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "=",
                                                    charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        XCTAssertTrue(canvas.performKeyEquivalent(with: zoomIn))
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                   keyCode: Key.escape))
        XCTAssertFalse(canvas.performKeyEquivalent(with: plain), "Only ⌘ keys")
        canvas.keyDown(with: plain)
        XCTAssertEqual(events(), [.zoom(1), .cancelled])
    }

    func testToolbarActions() {
        let (canvas, events) = makeCanvas()
        XCTAssertFalse(canvas.toolbarState.showsScrollCapture, "No scrolling capture from a long image")
        canvas.perform(.tool(.mosaic))
        canvas.perform(.mosaicShape(.brush))
        canvas.perform(.mosaicEffect(.solid))
        canvas.perform(.mosaicStrength(.high))
        XCTAssertTrue(canvas.toolbarState.showsMosaicOptions)
        XCTAssertEqual(canvas.toolbarState.mosaicShape, .brush)
        XCTAssertEqual(canvas.toolbarState.mosaicEffect, .solid)
        XCTAssertEqual(canvas.toolbarState.mosaicStrength, .high)
        canvas.perform(.tool(.pen))
        canvas.perform(.color(.blue))
        canvas.perform(.width(.thin))
        XCTAssertEqual(canvas.toolbarState.style, ScreenshotAnnotationStyle(color: .blue, width: .thin))
        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        XCTAssertTrue(canvas.toolbarState.canUndo)
        canvas.perform(.undo)
        XCTAssertTrue(canvas.toolbarState.canRedo)
        canvas.perform(.redo)
        canvas.perform(.scrollCapture)
        canvas.perform(.copy)
        canvas.perform(.save)
        canvas.perform(.cancel)
        let marks = canvas.editor.document.annotations
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(events(), [.finish(.copy, marks), .finish(.save, marks), .cancelled])
    }

    func testTypingText() throws {
        let (canvas, events) = makeCanvas()
        canvas.handleKeyDown(ScreenshotAnnotationTool.text.keyCode, modifiers: [])
        canvas.mouseDown(at: CGPoint(x: 30, y: 1200), clickCount: 1)
        let field = try XCTUnwrap(canvas.textField)
        field.stringValue = "Long"
        canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertGreaterThan(field.frame.width, 20)
        XCTAssertTrue(canvas.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertNil(canvas.textField)
        guard case let .text(origin, text, _)? = canvas.editor.document.annotations.first?.kind else {
            return XCTFail("No text")
        }
        XCTAssertEqual(origin, CGPoint(x: 30, y: 1200))
        XCTAssertEqual(text, "Long")

        // Double click edits it; esc keeps it as it was.
        canvas.handleKeyDown(ScreenshotAnnotationTool.text.keyCode, modifiers: [])
        canvas.mouseDown(at: CGPoint(x: 35, y: 1205), clickCount: 2)
        let editing = try XCTUnwrap(canvas.textField)
        XCTAssertEqual(editing.stringValue, "Long")
        editing.stringValue = "Changed"
        XCTAssertTrue(canvas.control(editing, textView: NSTextView(),
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(canvas.control(editing, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        guard case let .text(_, kept, _)? = canvas.editor.document.annotations.first?.kind else {
            return XCTFail("No text")
        }
        XCTAssertEqual(kept, "Long")
        canvas.cancelTextEditing()

        // Finishing commits what is being typed. (The key above put the text tool down; this picks it up.)
        canvas.handleKeyDown(ScreenshotAnnotationTool.text.keyCode, modifiers: [])
        canvas.mouseDown(at: CGPoint(x: 30, y: 300), clickCount: 1)
        canvas.textField?.stringValue = "More"
        canvas.perform(.copy)
        guard case let .finish(.copy, marks)? = events().last else { return XCTFail("No finish") }
        XCTAssertEqual(marks.count, 2)
    }

    func testMosaicsAreSizedToTheTextUnderThem() throws {
        let measurer = Measurer()
        let (canvas, _) = makeCanvas(measurer: measurer)
        canvas.handleKeyDown(ScreenshotAnnotationTool.mosaic.keyCode, modifiers: [])
        drag(canvas, from: CGPoint(x: 10, y: 1000), to: CGPoint(x: 60, y: 1020))

        XCTAssertEqual(measurer.measured, [CGSize(width: 100, height: 40)], "The image's pixels under it")
        XCTAssertEqual(try XCTUnwrap(canvas.editor.document.annotations.first?.mosaic).textHeight, 15)
        canvas.releaseImage()
    }

    func testTheImageIsDrawnPieceByPiece() throws {
        let image = ScrollCaptureFixtures.page(width: 40, height: 400).frameImage(offset: 0, scrollingHeight: 400)
        let canvas = ScreenshotLongImageCanvas(image: image, scale: 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: ScrollCaptureFixtures.space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 200)
        context.scaleBy(x: 1, y: -1)

        canvas.drawImage(in: CGRect(x: 0, y: 100, width: 20, height: 50), context: context)
        canvas.drawImage(in: CGRect(x: 0, y: 900, width: 20, height: 50), context: context)

        let drawn = ScrollCaptureFixtures.bytes(of: try XCTUnwrap(context.makeImage()))
        // Only rows 100–150 got paint.
        XCTAssertEqual(drawn[(10 * 20 + 5) * 4 + 3], 0)
        XCTAssertEqual(drawn[(120 * 20 + 5) * 4 + 3], 255)
    }

    // MARK: Editor view

    func testTheEditorShowsTheImageFittedToItsWidth() throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 })
        var events: [ScreenshotOverlayEvent] = []
        let display = ScreenSnapshot.Display(id: 4, frame: CGRect(x: 0, y: 0, width: 1000, height: 3000), scale: 2,
                                             image: ScreenCaptureTestSupport.image(width: 2000, height: 6000))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { events.append($0) }
        defer { controller.dismiss() }

        let view = try XCTUnwrap(controller.editorView)
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.frame, CGRect(x: 0, y: 0, width: 900, height: 700))
        let scrollFrame = ScreenshotLongImageEditorView.scrollFrame(in: view.bounds)
        XCTAssertEqual(view.scrollView.frame, scrollFrame)
        XCTAssertEqual(view.minimap.frame.minX, scrollFrame.maxX + ScreenshotLongImageEditorView.gap)
        // 1000 points wide in a narrower view: shrunk to the width.
        XCTAssertEqual(view.scrollView.magnification, view.fittingMagnification, accuracy: 0.001)
        XCTAssertLessThan(view.fittingMagnification, 1)
        XCTAssertEqual(view.canvas.visibleRect.minY, 0, accuracy: 1, "Starts at the top")
        XCTAssertEqual(view.canvas.visibleRect.width, 1000, accuracy: 2)
        XCTAssertNotNil(view.toolbar)
        XCTAssertGreaterThanOrEqual(view.toolbar?.frame.minY ?? 0, scrollFrame.maxY - ScreenshotOverlayView.toolbarShadowInset)

        view.canvas.handleKeyDown(Key.escape, modifiers: [])
        view.canvas.handleKeyDown(Key.keyS, modifiers: .command)
        XCTAssertEqual(events, [.cancelled, .finish(.save, displayID: 4, rect: display.frame, annotations: [])])
    }

    func testZoomStepsAndLimits() throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 })
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 3000), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 200, height: 3000))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { _ in }
        defer { controller.dismiss() }
        let view = try XCTUnwrap(controller.editorView)

        XCTAssertEqual(view.fittingMagnification, 1, "A narrow image is not enlarged")
        XCTAssertEqual(view.scrollView.magnification, 1, accuracy: 0.001)
        view.canvas.handleKeyDown(24, modifiers: .command, characters: "=")
        XCTAssertEqual(view.scrollView.magnification, 1.25, accuracy: 0.001)
        for _ in 0 ..< 20 { view.zoom(1) }
        XCTAssertEqual(view.scrollView.magnification, ScreenshotLongImageEditorView.maxMagnification, accuracy: 0.001)
        for _ in 0 ..< 40 { view.zoom(-1) }
        XCTAssertEqual(view.scrollView.magnification, view.minimumMagnification, accuracy: 0.001)
        XCTAssertLessThan(view.minimumMagnification, 0.25, "Out far enough to see the whole image")
        view.zoom(0)
        XCTAssertEqual(view.scrollView.magnification, 1, accuracy: 0.001)
    }

    func testTheMinimapJumpsAndFollows() throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 })
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 4000), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 400, height: 4000))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { _ in }
        defer { controller.dismiss() }
        let view = try XCTUnwrap(controller.editorView)
        let minimap = view.minimap
        XCTAssertNotNil(minimap.thumbnail)
        XCTAssertEqual(minimap.imageSize, CGSize(width: 400, height: 4000))
        XCTAssertEqual(minimap.viewport.minY, 0, accuracy: 1)

        let imageFrame = ScreenshotLongImageMinimapView.imageFrame(imageSize: minimap.imageSize, in: minimap.bounds)
        minimap.jump(to: CGPoint(x: imageFrame.midX, y: imageFrame.midY))

        XCTAssertEqual(view.canvas.visibleRect.midY, 2000, accuracy: 2)
        XCTAssertEqual(minimap.viewport, view.canvas.visibleRect)
        minimap.jump(to: CGPoint(x: imageFrame.midX, y: imageFrame.maxY + 50))
        XCTAssertEqual(view.canvas.visibleRect.maxY, 4000, accuracy: 2, "Clamped at the end")

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertNotNil(bitmap.colorAt(x: 10, y: 10))
    }

    func testTheEditorDrawsMarksAsTheUserDragsPastTheEdge() throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 })
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 4000), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 400, height: 4000))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { _ in }
        defer { controller.dismiss() }
        let canvas = try XCTUnwrap(controller.editorView).canvas
        let bottom = canvas.visibleRect.maxY

        canvas.handleKeyDown(ScreenshotAnnotationTool.pen.keyCode, modifiers: [])
        canvas.mouseDown(at: CGPoint(x: 100, y: bottom - 20), clickCount: 1)
        canvas.mouseDragged(to: CGPoint(x: 100, y: bottom + 100))
        canvas.mouseUp(at: CGPoint(x: 100, y: bottom + 100))

        XCTAssertGreaterThan(canvas.visibleRect.maxY, bottom, "Scrolled along")
        XCTAssertEqual(canvas.editor.document.annotations.count, 1)
        // Releasing outside a drag does nothing.
        canvas.mouseDragged(to: .zero)
        canvas.mouseUp(at: .zero)
        XCTAssertEqual(canvas.editor.document.annotations.count, 1)
    }

    func testPresentingAgainReplacesTheEditor() throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 })
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 400), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 100, height: 400))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { _ in }
        let first = try XCTUnwrap(controller.panel)
        controller.present(display, on: CGRect(x: 0, y: 0, width: 900, height: 700)) { _ in }

        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(try XCTUnwrap(controller.panel).isVisible)
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertNil(controller.editorView)
        controller.dismiss()
    }

    // MARK: Minimap and clip view

    func testMinimapGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 72, height: 412)
        let size = CGSize(width: 600, height: 6000)
        let frame = ScreenshotLongImageMinimapView.imageFrame(imageSize: size, in: bounds)
        // Limited by the height: 400 tall, 40 wide, centered.
        XCTAssertEqual(frame, CGRect(x: 16, y: 6, width: 40, height: 400))
        XCTAssertEqual(ScreenshotLongImageMinimapView.imagePoint(for: CGPoint(x: 36, y: 206), imageSize: size,
                                                                in: bounds), CGPoint(x: 300, y: 3000))
        XCTAssertEqual(ScreenshotLongImageMinimapView.imagePoint(for: CGPoint(x: -5, y: 900), imageSize: size,
                                                                in: bounds), CGPoint(x: 0, y: 6000))
        XCTAssertEqual(ScreenshotLongImageMinimapView.viewportFrame(visible: CGRect(x: 0, y: 1500, width: 600, height: 600),
                                                                   imageSize: size, in: bounds),
                       CGRect(x: 16, y: 106, width: 40, height: 40))
        XCTAssertEqual(ScreenshotLongImageMinimapView.imageFrame(imageSize: .zero, in: bounds), .zero)
        XCTAssertNil(ScreenshotLongImageMinimapView.imagePoint(for: .zero, imageSize: .zero, in: bounds))
        XCTAssertEqual(ScreenshotLongImageMinimapView.viewportFrame(visible: CGRect(x: 0, y: 9000, width: 10, height: 10),
                                                                   imageSize: size, in: bounds), .zero)
        // A short, wide image is limited by the width.
        XCTAssertEqual(ScreenshotLongImageMinimapView.imageFrame(imageSize: CGSize(width: 600, height: 60), in: bounds),
                       CGRect(x: 6, y: 6, width: 60, height: 6))
    }

    func testAMinimapWithoutAnImageDoesNothing() {
        let minimap = ScreenshotLongImageMinimapView(frame: CGRect(x: 0, y: 0, width: 72, height: 300))
        var jumps = 0
        minimap.onJump = { _ in jumps += 1 }
        minimap.jump(to: CGPoint(x: 10, y: 10))
        XCTAssertEqual(jumps, 0)
        XCTAssertTrue(minimap.acceptsFirstMouse(for: nil))
    }

    func testASmallDocumentSitsInTheMiddle() {
        let clip = ScreenshotCenteringClipView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        clip.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 1000))

        let constrained = clip.constrainBoundsRect(CGRect(x: 0, y: 0, width: 400, height: 300))

        XCTAssertEqual(constrained.minX, -150)
        XCTAssertEqual(constrained.minY, 0, "Taller than the view: scrolls as usual")
        clip.documentView = nil
        XCTAssertEqual(clip.constrainBoundsRect(CGRect(x: 0, y: 0, width: 400, height: 300)).minX, 0)
    }
}
