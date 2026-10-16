import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// Callouts, ellipse mosaics and mosaics that only cover text.
@MainActor
final class ScreenshotCalloutMosaicTests: XCTestCase {
    private typealias Style = ScreenshotAnnotationStyle
    private let crop = CGRect(x: 0, y: 0, width: 400, height: 300)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Finds the lines it is given, in the pixels of whatever image it is handed.
    private final class LineFinder: ScreenshotTextHeightMeasuring {
        var lines: [CGRect] = []
        private(set) var images: [CGSize] = []

        func geometry(in image: CGImage) async throws -> ScreenshotTextGeometry {
            images.append(CGSize(width: image.width, height: image.height))
            return .init(lines: lines, height: 7)
        }
    }

    private func draw(_ editor: inout ScreenshotAnnotationEditor, from start: CGPoint, to end: CGPoint) {
        _ = editor.mouseDown(at: start, crop: crop, cropHit: .inside)
        editor.mouseDragged(to: end)
        editor.mouseUp(at: end)
    }

    // MARK: Callouts

    func testACalloutWaitsForItsTextThenJoinsTheDocument() throws {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.callout)
        draw(&editor, from: CGPoint(x: 50, y: 200), to: CGPoint(x: 150, y: 80))
        let draft = try XCTUnwrap(editor.calloutDraft)
        XCTAssertEqual(draft.kind, .callout(anchor: CGPoint(x: 50, y: 200), origin: CGPoint(x: 150, y: 80), "",
                                            fontSize: 15))
        XCTAssertTrue(editor.document.isEmpty)
        XCTAssertEqual(editor.visibleAnnotations.count, 1, "Its line and box show while typing")

        editor.commitText("Check this", at: .zero)
        XCTAssertNil(editor.calloutDraft)
        XCTAssertEqual(editor.document.annotations.first?.kind,
                       .callout(anchor: CGPoint(x: 50, y: 200), origin: CGPoint(x: 150, y: 80), "Check this",
                                fontSize: 15))
        XCTAssertEqual(editor.document.undoDepth, 1)

        draw(&editor, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 310, y: 150))
        editor.commitText("   ", at: .zero)
        XCTAssertEqual(editor.document.annotations.count, 1, "An empty callout is dropped")
        draw(&editor, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 310, y: 150))
        editor.cancelText()
        XCTAssertNil(editor.calloutDraft)
        XCTAssertEqual(editor.document.annotations.count, 1)
    }

    func testCalloutGeometry() throws {
        var style = ScreenshotAnnotationTool.callout.defaultStyle
        let callout = ScreenshotAnnotation(kind: .callout(anchor: CGPoint(x: 120, y: 250),
                                                          origin: CGPoint(x: 100, y: 50), "Note", fontSize: 15),
                                           style: style)
        let box = try XCTUnwrap(callout.calloutBox)
        XCTAssertTrue(box.contains(CGPoint(x: 101, y: 51)))
        XCTAssertEqual(callout.calloutLineStart, CGPoint(x: box.midX, y: box.maxY), "The side facing the anchor")
        XCTAssertTrue(callout.frame.contains(box))
        XCTAssertEqual(callout.frame.maxY, 250)
        XCTAssertTrue(callout.contains(CGPoint(x: box.midX, y: box.midY)))
        XCTAssertTrue(callout.contains(CGPoint(x: 121, y: 249)), "The anchor")
        let start = try XCTUnwrap(callout.calloutLineStart)
        XCTAssertTrue(callout.contains(CGPoint(x: (start.x + 120) / 2, y: (start.y + 250) / 2)), "The line")
        XCTAssertFalse(callout.contains(CGPoint(x: 300, y: 280)))
        XCTAssertFalse(callout.isResizable)
        XCTAssertEqual(callout.bendHandle, CGPoint(x: 120, y: 250), "The anchor is its handle")
        XCTAssertEqual(callout.editableText?.text, "Note")
        XCTAssertEqual(callout.size, 15)
        XCTAssertEqual(callout.tool, .callout)

        var resized = callout
        resized.size = 20
        XCTAssertEqual(resized.kind, .callout(anchor: CGPoint(x: 120, y: 250), origin: CGPoint(x: 100, y: 50), "Note",
                                              fontSize: 20))
        let moved = callout.offsetBy(dx: 5, dy: 5)
        XCTAssertEqual(moved.kind, .callout(anchor: CGPoint(x: 125, y: 255), origin: CGPoint(x: 105, y: 55), "Note",
                                            fontSize: 15))
        let boxMoved = callout.movingCalloutBox(dx: 10, dy: 0)
        XCTAssertEqual(boxMoved.kind, .callout(anchor: CGPoint(x: 120, y: 250), origin: CGPoint(x: 110, y: 50), "Note",
                                               fontSize: 15))
        XCTAssertEqual(ScreenshotAnnotation(kind: .rect(.zero)).movingCalloutBox(dx: 1, dy: 1).kind,
                       .rect(CGRect(x: 1, y: 1, width: 0, height: 0)))

        let inside = ScreenshotAnnotation(kind: .callout(anchor: CGPoint(x: 105, y: 55), origin: CGPoint(x: 100, y: 50),
                                                         "Note", fontSize: 15), style: style)
        XCTAssertNil(inside.calloutLineStart, "No line when the anchor is under the box")
        XCTAssertEqual(ScreenshotAnnotation.calloutLineWidth(fontSize: 11), 2)
        XCTAssertEqual(ScreenshotAnnotation.calloutLineWidth(fontSize: 35), 5)

        style.textStyle = .outline
        XCTAssertEqual(ScreenshotAnnotation.editingTextColor(style, callout: true), CGColor(gray: 1, alpha: 1))
        style.textStyle = .plain
        XCTAssertEqual(ScreenshotAnnotation.editingTextColor(style, callout: true), style.color.cgColor())
        style.textStyle = .background
        XCTAssertEqual(ScreenshotAnnotation.editingTextColor(style, callout: true), style.color.contrastingTextColor)
        XCTAssertEqual(ScreenshotAnnotation.editingTextColor(style, callout: false), style.color.cgColor())
    }

    func testDraggingACalloutMovesItsBoxAndTheHandleMovesItsAnchor() throws {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.callout)
        draw(&editor, from: CGPoint(x: 50, y: 200), to: CGPoint(x: 150, y: 80))
        editor.commitText("Box", at: .zero)
        let box = try XCTUnwrap(editor.document.annotations.first?.calloutBox)

        _ = editor.mouseDown(at: CGPoint(x: box.midX, y: box.midY), crop: crop, cropHit: .inside)
        editor.mouseDragged(to: CGPoint(x: box.midX + 30, y: box.midY))
        editor.mouseUp(at: CGPoint(x: box.midX + 30, y: box.midY))
        XCTAssertEqual(editor.selected?.kind, .callout(anchor: CGPoint(x: 50, y: 200), origin: CGPoint(x: 180, y: 80),
                                                       "Box", fontSize: 15))
        XCTAssertTrue(editor.selectionHandles.isEmpty)
        XCTAssertEqual(editor.bendHandle, CGPoint(x: 50, y: 200))

        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 51, y: 201), crop: crop, cropHit: .inside), .handled)
        editor.mouseDragged(to: CGPoint(x: 20, y: 250))
        editor.mouseUp(at: CGPoint(x: 20, y: 250))
        XCTAssertEqual(editor.selected?.kind, .callout(anchor: CGPoint(x: 20, y: 250), origin: CGPoint(x: 180, y: 80),
                                                       "Box", fontSize: 15))
        XCTAssertEqual(editor.document.undoDepth, 3)

        // Double-click edits the text; the line and box stay while it is typed.
        let current = try XCTUnwrap(editor.selected?.calloutBox)
        let id = try XCTUnwrap(editor.selectedID)
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: current.midX, y: current.midY), clickCount: 2, crop: crop,
                                        cropHit: .inside), .editText(id))
        XCTAssertEqual(editor.visibleAnnotations.first?.editableText?.text, "")
        editor.commitText("Boxes", at: .zero)
        XCTAssertEqual(editor.document.annotations.first?.editableText?.text, "Boxes")
        _ = editor.mouseDown(at: CGPoint(x: current.midX, y: current.midY), clickCount: 2, crop: crop, cropHit: .inside)
        editor.commitText("", at: .zero)
        XCTAssertTrue(editor.document.isEmpty, "Emptied, it goes")

        XCTAssertEqual(editor.tool, .callout)
        editor.setCalloutAnchor(.arrow)
        XCTAssertEqual(editor.toolStyles[.callout].calloutAnchor, .arrow)
        XCTAssertTrue(editor.apply(.calloutAnchor(.plain)))
        XCTAssertEqual(editor.toolStyles[.callout].calloutAnchor, .plain)
    }

    func testCalloutsRenderTheirLineEndAndBox() throws {
        func render(_ style: Style) throws -> ScreenshotMosaicEffects.Pixels {
            let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 120), scale: 1,
                                                 image: ScreenCaptureTestSupport.image(width: 200, height: 120))
            let callout = ScreenshotAnnotation(kind: .callout(anchor: CGPoint(x: 30, y: 100),
                                                              origin: CGPoint(x: 100, y: 20), "Hi", fontSize: 16),
                                               style: style)
            return try XCTUnwrap(ScreenshotMosaicEffects.Pixels(
                ScreenshotRenderer.render(display, crop: display.frame, annotations: [callout]), space: Self.sRGB
            ))
        }
        func rgb(_ pixels: ScreenshotMosaicEffects.Pixels, _ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return pixels.bytes[offset ..< offset + 3].map(Int.init)
        }
        var style = Style(color: .blue, size: 16)
        style.textStyle = .background
        let dot = try render(style)
        XCTAssertGreaterThan(rgb(dot, 31, 100)[2], 200, "The dot")
        XCTAssertGreaterThan(rgb(dot, 96, 30)[2], 200, "The box")
        style.calloutAnchor = .plain
        style.textStyle = .outline
        let outlined = try render(style)
        XCTAssertLessThan(rgb(outlined, 98, 30)[0], 100, "A dark box")
        style.textStyle = .plain
        style.calloutAnchor = .arrow
        let plain = try render(style)
        XCTAssertEqual(rgb(plain, 96, 22)[0], rgb(plain, 2, 2)[0], accuracy: 4, "No box behind plain text")
        XCTAssertGreaterThan(rgb(plain, 62, 65)[2], 200, "The line")
    }

    // MARK: Mosaics

    func testEllipseMosaics() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.mosaic)
        editor.setMosaicShape(.ellipse)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        guard let mosaic = editor.document.annotations.first?.mosaic else { return XCTFail("No mosaic") }
        XCTAssertEqual(mosaic.shape, .ellipse(CGRect(x: 10, y: 10, width: 100, height: 50)))
        XCTAssertTrue(mosaic.maskPath.contains(CGPoint(x: 60, y: 35)))
        XCTAssertFalse(mosaic.maskPath.contains(CGPoint(x: 12, y: 12)), "Not in the corners")
        XCTAssertTrue(mosaic.shape.coversArea)
        XCTAssertFalse(ScreenshotMosaic.Shape.brush([.zero], width: 3).coversArea)
        let annotation = editor.document.annotations[0]
        XCTAssertTrue(annotation.contains(CGPoint(x: 60, y: 35)))
        XCTAssertFalse(annotation.contains(CGPoint(x: 11, y: 11)))
        XCTAssertEqual(annotation.offsetBy(dx: 5, dy: 0).mosaic?.shape, .ellipse(CGRect(x: 15, y: 10, width: 100,
                                                                                         height: 50)))
        XCTAssertEqual(annotation.resized(from: annotation.frame, to: CGRect(x: 0, y: 0, width: 50, height: 25))
            .mosaic?.shape, .ellipse(CGRect(x: 0, y: 0, width: 50, height: 25)))
        draw(&editor, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 201, y: 201))
        XCTAssertEqual(editor.document.annotations.count, 1, "Too small to keep")
    }

    func testTheTextScopeCoversOnlyTheLinesFoundInsideTheShape() throws {
        var editor = ScreenshotAnnotationEditor()
        var asked: [CGRect] = []
        let lines = [CGRect(x: 20, y: 20, width: 80, height: 10), CGRect(x: 20, y: 40, width: 60, height: 12),
                     CGRect(x: 300, y: 300, width: 10, height: 10)]
        editor.locateText = { rect in
            asked.append(rect)
            return lines
        }
        editor.measureTextHeight = { _ in 99 }
        editor.selectTool(.mosaic)
        editor.setMosaicScope(.text)
        XCTAssertEqual(editor.mosaicScope, .text)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        let mosaic = try XCTUnwrap(editor.document.annotations.first?.mosaic)
        XCTAssertEqual(asked, [CGRect(x: 10, y: 10, width: 190, height: 90)])
        XCTAssertEqual(mosaic.textRuns, Array(lines.prefix(2)), "Lines outside the shape are left out")
        XCTAssertEqual(mosaic.scope, .text)
        XCTAssertEqual(mosaic.textHeight, 12, "Measured from the lines")
        XCTAssertEqual(mosaic.clipPaths.count, 2)
        XCTAssertTrue(mosaic.clipPaths[1].contains(CGPoint(x: 19, y: 25)), "Grown by the margin")
        XCTAssertFalse(mosaic.clipPaths[1].contains(CGPoint(x: 150, y: 80)))

        // The runs move with the mosaic.
        XCTAssertEqual(editor.document.annotations[0].offsetBy(dx: 0, dy: 10).mosaic?.textRuns?.first,
                       CGRect(x: 20, y: 30, width: 80, height: 10))
        let scaled = editor.document.annotations[0].resized(from: CGRect(x: 10, y: 10, width: 190, height: 90),
                                                            to: CGRect(x: 10, y: 10, width: 380, height: 90))
        XCTAssertEqual(scaled.mosaic?.textRuns?.first, CGRect(x: 30, y: 20, width: 160, height: 10))

        // Selected, it can cover everything again, or only its text.
        _ = editor.mouseDown(at: CGPoint(x: 150, y: 80), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 150, y: 80))
        editor.setMosaicScope(.all)
        XCTAssertNil(editor.selected?.mosaic?.textRuns)
        XCTAssertEqual(editor.selected?.mosaic?.textHeight, 99)
        XCTAssertEqual(editor.mosaicScope, .all)
        editor.setMosaicScope(.text)
        XCTAssertEqual(editor.selected?.mosaic?.textRuns?.count, 2)
        XCTAssertEqual(editor.toolStyles.mosaicScope, .text)
    }

    func testTheTextScopeFallsBackToTheWholeShapeAndSkipsBrushes() throws {
        var editor = ScreenshotAnnotationEditor()
        editor.measureTextHeight = { _ in 9 }
        editor.selectTool(.mosaic)
        XCTAssertTrue(editor.apply(.mosaicScope(.text)))
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        let empty = try XCTUnwrap(editor.document.annotations.first?.mosaic)
        XCTAssertNil(empty.textRuns, "No text found: everything is covered")
        XCTAssertEqual(empty.textHeight, 9)

        editor.locateText = { _ in [CGRect(x: 20, y: 20, width: 30, height: 8)] }
        editor.setMosaicShape(.brush)
        draw(&editor, from: CGPoint(x: 10, y: 150), to: CGPoint(x: 100, y: 150))
        XCTAssertNil(editor.document.annotations.last?.mosaic?.textRuns, "A brush covers what it paints")
    }

    func testTextOnlyMosaicsLeaveTheRestOfTheShapeClear() throws {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 60), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 100, height: 60))
        var mosaic = ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 100, height: 60)), effect: .solid)
        mosaic.textRuns = [CGRect(x: 10, y: 10, width: 30, height: 10)]
        let pixels = try XCTUnwrap(ScreenshotMosaicEffects.Pixels(
            ScreenshotRenderer.render(display, crop: display.frame,
                                      annotations: [ScreenshotAnnotation(kind: .mosaic(mosaic),
                                                                         style: Style(color: .red))]),
            space: Self.sRGB
        ))
        func red(_ x: Int, _ y: Int) -> Int { Int(pixels.bytes[(y * pixels.width + x) * 4]) }
        XCTAssertGreaterThan(red(20, 15), 240, "The line is covered")
        XCTAssertEqual(red(70, 40), red(98, 58), accuracy: 4, "The rest is left alone")
        XCTAssertLessThan(red(70, 40), 200)
    }

    func testTheOverlayFindsTextLinesInTheFrozenImage() async throws {
        let finder = LineFinder()
        // Lines in the pixels of the piece under the mosaic.
        finder.lines = [CGRect(x: 20, y: 20, width: 100, height: 20)]
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2,
                                             image: ScreenCaptureTestSupport.image(width: 800, height: 600))
        let view = ScreenshotOverlayView(display: display, windows: [], textMeasurer: finder)
        view.mouseDown(at: CGPoint(x: 50, y: 50), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 350, y: 250))
        view.mouseUp(at: CGPoint(x: 350, y: 250))
        view.toolbarModel.perform(.tool(.mosaic))
        view.toolbarModel.perform(.mosaicScope(.text))
        XCTAssertEqual(view.toolbarModel.state.mosaicScope, .text)
        view.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 200, y: 160))
        view.mouseUp(at: CGPoint(x: 200, y: 160))

        try await MosaicGeometryIsolationTests.waitFor { view.mosaicPreparation.state != .preparing }
        XCTAssertEqual(finder.images, [CGSize(width: 200, height: 120)], "Only the piece under the mosaic")
        let runs = try XCTUnwrap(view.editor.document.annotations.first?.mosaic?.textRuns)
        XCTAssertEqual(runs, [CGRect(x: 110, y: 110, width: 50, height: 10)], "In the display's points")
    }

    func testTheOverlayAndLongImageTypeACalloutsTextAfterTheDrag() throws {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 400, height: 300))
        let view = ScreenshotOverlayView(display: display, windows: [])
        view.mouseDown(at: CGPoint(x: 20, y: 20), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 380, y: 280))
        view.mouseUp(at: CGPoint(x: 380, y: 280))
        XCTAssertTrue(view.handleKeyDown(ScreenshotAnnotationTool.callout.keyCode, modifiers: []))
        view.mouseDown(at: CGPoint(x: 60, y: 200), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 200, y: 80))
        view.mouseUp(at: CGPoint(x: 200, y: 80))
        let field = try XCTUnwrap(view.textField, "Typing starts in the box")
        field.stringValue = "Look"
        view.endTextEditing()
        XCTAssertEqual(view.editor.document.annotations.first?.editableText?.text, "Look")

        let canvas = ScreenshotLongImageCanvas(image: ScreenCaptureTestSupport.image(width: 300, height: 600), scale: 1)
        canvas.perform(.tool(.callout))
        canvas.mouseDown(at: CGPoint(x: 30, y: 400), clickCount: 1)
        canvas.mouseDragged(to: CGPoint(x: 150, y: 300))
        canvas.mouseUp(at: CGPoint(x: 150, y: 300))
        let longField = try XCTUnwrap(canvas.textField)
        longField.stringValue = "There"
        canvas.endTextEditing()
        XCTAssertEqual(canvas.editor.document.annotations.first?.editableText?.text, "There")
        canvas.releaseImage()
        view.releaseImage()
    }

    func testCalloutAndScopeOptionsRenderAndRoundTrip() async throws {
        func width(_ tool: ScreenshotAnnotationTool, mosaicShape: ScreenshotAnnotationEditor.MosaicShape = .rect)
            -> CGFloat {
            var state = ScreenshotEditorToolbarModel.State()
            state.showsOptions = true
            state.tool = tool
            state.optionsTool = tool
            state.showsMosaicOptions = tool == .mosaic
            state.mosaicShape = mosaicShape
            return NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar).fittingSize.width
        }
        XCTAssertGreaterThan(width(.callout), width(.line))
        XCTAssertNotEqual(width(.mosaic), width(.mosaic, mosaicShape: .brush), "Boxes offer the scope, brushes a size")
        for anchor in Style.CalloutAnchor.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: anchor).isEmpty)
        }
        XCTAssertEqual(ScreenshotEditorToolbarModel.sizeCaption(for: .callout),
                       ScreenshotEditorToolbarModel.sizeCaption(for: .text))

        var styles = ScreenshotToolStyles()
        styles.mosaicScope = .text
        styles[.callout].calloutAnchor = .arrow
        XCTAssertEqual(try JSONDecoder().decode(ScreenshotToolStyles.self, from: JSONEncoder().encode(styles)), styles)
        XCTAssertEqual(ScreenshotAnnotationTool.callout.defaultStyle.textStyle, .background)
        XCTAssertEqual(VisionTextHeightMeasurer.pixelRects(normalizedBoxes: [CGRect(x: 0.1, y: 0.5, width: 0.5,
                                                                                     height: 0.25)],
                                                           imageWidth: 200, imageHeight: 100),
                       [CGRect(x: 20, y: 25, width: 100, height: 25)], "Flipped to a top-left origin")
        let geometry = try await VisionTextHeightMeasurer(recognizer: .init(worker: MediaWorker(timeout: 30))).geometry(in: ScreenCaptureTestSupport.image(width: 200, height: 200))
        XCTAssertTrue(geometry.lines.isEmpty, "No text in a gray square")
    }
}
