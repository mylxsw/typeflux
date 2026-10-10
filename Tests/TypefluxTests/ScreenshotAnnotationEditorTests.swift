import CoreGraphics
@testable import Typeflux
import XCTest

final class ScreenshotAnnotationEditorTests: XCTestCase {
    private let crop = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func draw(_ editor: inout ScreenshotAnnotationEditor, from start: CGPoint, to end: CGPoint,
                      shift: Bool = false) {
        XCTAssertEqual(editor.mouseDown(at: start, crop: crop, cropHit: .inside), .handled)
        editor.mouseDragged(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), shift: shift)
        editor.mouseDragged(to: end, shift: shift)
        editor.mouseUp(at: end, shift: shift)
    }

    private func editor(with tool: ScreenshotAnnotationTool) -> ScreenshotAnnotationEditor {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(tool)
        return editor
    }

    // MARK: Tools

    func testToolKeysAndShortcuts() {
        let letters = ScreenshotAnnotationTool.allCases.map(\.shortcut)
        XCTAssertEqual(letters, ["R", "O", "A", "P", "H", "T", "N", "M"])
        for tool in ScreenshotAnnotationTool.allCases {
            XCTAssertEqual(ScreenshotAnnotationTool(keyCode: tool.keyCode), tool)
        }
        XCTAssertNil(ScreenshotAnnotationTool(keyCode: 99))
    }

    func testSelectingAToolTwicePutsItDown() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.rect)
        XCTAssertEqual(editor.tool, .rect)
        editor.selectTool(.arrow)
        XCTAssertEqual(editor.tool, .arrow)
        editor.selectTool(.arrow)
        XCTAssertNil(editor.tool)
    }

    func testDrawingEachShape() {
        let start = CGPoint(x: 10, y: 10), end = CGPoint(x: 60, y: 40)
        let expected: [ScreenshotAnnotationTool: ScreenshotAnnotation.Kind] = [
            .rect: .rect(CGRect(x: 10, y: 10, width: 50, height: 30)),
            .ellipse: .ellipse(CGRect(x: 10, y: 10, width: 50, height: 30)),
            .arrow: .arrow(from: start, to: end),
            .pen: .path([start, CGPoint(x: 35, y: 25), end]),
            .highlighter: .highlight([start, CGPoint(x: 35, y: 25), end]),
            .counter: .counter(center: end)
        ]
        for (tool, kind) in expected {
            var editor = self.editor(with: tool)
            XCTAssertFalse(editor.isDragging)
            draw(&editor, from: start, to: end)
            XCTAssertEqual(editor.document.annotations.map(\.kind), [kind], "\(tool)")
            XCTAssertNil(editor.draft)
            XCTAssertNil(editor.selectedID, "Drawing keeps the tool, not a selection")
        }
    }

    func testTheDraftShowsWhileDrawing() {
        var editor = self.editor(with: .rect)
        _ = editor.mouseDown(at: CGPoint(x: 10, y: 10), crop: crop, cropHit: .inside)
        editor.mouseDragged(to: CGPoint(x: 30, y: 30))

        XCTAssertTrue(editor.isDragging)
        XCTAssertEqual(editor.visibleAnnotations.map(\.kind), [.rect(CGRect(x: 10, y: 10, width: 20, height: 20))])
        XCTAssertTrue(editor.document.isEmpty)
    }

    func testShiftMakesSquaresCirclesAndFortyFiveDegrees() {
        var square = self.editor(with: .rect)
        draw(&square, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 50, y: 130), shift: true)
        XCTAssertEqual(square.document.annotations.first?.frame, CGRect(x: 50, y: 100, width: 50, height: 50))

        var circle = self.editor(with: .ellipse)
        draw(&circle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 70), shift: true)
        XCTAssertEqual(circle.document.annotations.first?.frame, CGRect(x: 10, y: 10, width: 60, height: 60))

        var arrow = self.editor(with: .arrow)
        draw(&arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 10), shift: true)
        XCTAssertEqual(arrow.document.annotations.first?.kind,
                       .arrow(from: .zero, to: CGPoint(x: hypot(CGFloat(100), CGFloat(10)), y: 0)))

        var line = self.editor(with: .pen)
        draw(&line, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 52), shift: true)
        guard case let .path(points)? = line.document.annotations.first?.kind else { return XCTFail("No pen stroke") }
        XCTAssertEqual(points.count, 2, "A straight line")
        XCTAssertEqual(points[1].x - 10, points[1].y - 10, accuracy: 0.001, "At 45°")
    }

    func testConstraintHelpers() {
        XCTAssertEqual(ScreenshotAnnotationEditor.constrainedSquare(from: .zero, to: CGPoint(x: -10, y: 4)),
                       CGPoint(x: -10, y: 10))
        XCTAssertEqual(ScreenshotAnnotationEditor.constrainedAngle(from: .zero, to: .zero), .zero)
        XCTAssertEqual(ScreenshotAnnotationEditor.constrainedAngle(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 50)),
                       CGPoint(x: 5, y: 5 + hypot(CGFloat(1), CGFloat(45))))
        let diagonal = ScreenshotAnnotationEditor.constrainedAngle(from: .zero, to: CGPoint(x: -30, y: -28))
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
        XCTAssertLessThan(diagonal.x, 0)
    }

    func testStrayClicksAreNotKept() {
        for tool in [ScreenshotAnnotationTool.rect, .ellipse, .arrow, .mosaic] {
            var editor = self.editor(with: tool)
            draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))
            XCTAssertTrue(editor.document.isEmpty, "\(tool)")
        }
        var dot = self.editor(with: .pen)
        _ = dot.mouseDown(at: CGPoint(x: 10, y: 10), crop: crop, cropHit: .inside)
        dot.mouseDragged(to: CGPoint(x: 10.5, y: 10))
        dot.mouseUp(at: CGPoint(x: 10.5, y: 10))
        XCTAssertEqual(dot.document.annotations.first?.kind, .path([CGPoint(x: 10, y: 10)]), "A pen click is a dot")
        XCTAssertTrue(ScreenshotAnnotationEditor.isWorthKeeping(ScreenshotAnnotation(kind: .text(origin: .zero, "a",
                                                                                                fontSize: 12))))
        XCTAssertFalse(ScreenshotAnnotationEditor.isWorthKeeping(ScreenshotAnnotation(kind: .text(origin: .zero, "",
                                                                                                 fontSize: 12))))
    }

    func testPressesTheEditorLeavesToTheRegion() {
        var editor = ScreenshotAnnotationEditor()
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 10, y: 10), crop: crop, cropHit: .inside), .ignored,
                       "No tool: the region moves")
        editor.selectTool(.rect)
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 0, y: 0), crop: crop, cropHit: .handle(.topLeft)), .ignored)
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 500, y: 10), crop: crop, cropHit: .outside), .ignored)
        XCTAssertFalse(editor.mouseDragged(to: .zero))
        XCTAssertFalse(editor.mouseUp(at: .zero))
    }

    // MARK: Mosaic

    func testMosaicBoxAndBrushUseTheChosenOptionsAndMeasureText() {
        var editor = self.editor(with: .mosaic)
        var measured: [ScreenshotMosaic] = []
        editor.measureTextHeight = { mosaic in
            measured.append(mosaic)
            return 18
        }
        editor.setMosaicEffect(.blur)
        editor.setMosaicStrength(.high)
        XCTAssertTrue(editor.showsMosaicOptions)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30))

        let box = editor.document.annotations[0].mosaic
        XCTAssertEqual(box, ScreenshotMosaic(shape: .rect(CGRect(x: 10, y: 10, width: 40, height: 20)), effect: .blur,
                                             strength: .high, textHeight: 18))
        XCTAssertEqual(measured.count, 1)
        XCTAssertNil(measured[0].textHeight, "Measured before the height is known")

        editor.setMosaicShape(.brush)
        editor.setWidth(.thick)
        draw(&editor, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 100))
        guard case let .brush(points, width)? = editor.document.annotations[1].mosaic?.shape else {
            return XCTFail("No brush")
        }
        XCTAssertEqual(points.first, CGPoint(x: 100, y: 100))
        XCTAssertEqual(points.last, CGPoint(x: 140, y: 100))
        XCTAssertEqual(width, 44)
    }

    func testChangingMosaicOptionsChangesTheSelectedMosaic() {
        var editor = self.editor(with: .mosaic)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30))
        editor.selectTool(nil)
        XCTAssertFalse(editor.showsMosaicOptions)
        _ = editor.mouseDown(at: CGPoint(x: 20, y: 20), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 20, y: 20))
        XCTAssertTrue(editor.showsMosaicOptions, "A selected mosaic shows its options")

        editor.setMosaicEffect(.solid)
        editor.setMosaicStrength(.low)
        XCTAssertEqual(editor.selected?.mosaic?.effect, .solid)
        XCTAssertEqual(editor.selected?.mosaic?.strength, .low)
        XCTAssertEqual(editor.document.undoDepth, 3)

        // Mosaic options leave other annotations alone.
        var other = self.editor(with: .rect)
        draw(&other, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30))
        _ = other.mouseDown(at: CGPoint(x: 10, y: 20), crop: crop, cropHit: .inside)
        other.setMosaicEffect(.blur)
        other.setMosaicStrength(.high)
        XCTAssertEqual(other.document.undoDepth, 1)
    }

    // MARK: Selecting

    func testPressingAnAnnotationSelectsAndMovesItInOneUndoStep() {
        var editor = self.editor(with: .rect)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        let id = editor.document.annotations[0].id

        // On the outline: select and move, even with a tool picked.
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 10, y: 25), crop: crop, cropHit: .inside), .handled)
        XCTAssertEqual(editor.selectedID, id)
        editor.mouseDragged(to: CGPoint(x: 15, y: 25))
        editor.mouseDragged(to: CGPoint(x: 30, y: 35))
        editor.mouseUp(at: CGPoint(x: 30, y: 35))

        XCTAssertEqual(editor.selected?.frame, CGRect(x: 30, y: 20, width: 50, height: 30))
        XCTAssertEqual(editor.document.undoDepth, 2)
        editor.undo()
        XCTAssertEqual(editor.selected?.frame, CGRect(x: 10, y: 10, width: 50, height: 30))
        XCTAssertEqual(editor.selectionHandles.count, 4)

        // Inside an unfilled box draws a new one instead.
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 35, y: 25), crop: crop, cropHit: .inside), .handled)
        XCTAssertNil(editor.selectedID)
        editor.mouseUp(at: CGPoint(x: 35, y: 25))
    }

    func testCornerHandlesResizeTheSelection() {
        var editor = self.editor(with: .ellipse)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        _ = editor.mouseDown(at: CGPoint(x: 10, y: 25), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 10, y: 25))
        XCTAssertNotNil(editor.selectedID)

        // The bottom-right handle wins over the region's handle at the same place.
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 61, y: 41), crop: crop, cropHit: .handle(.bottomRight)),
                       .handled)
        editor.mouseDragged(to: CGPoint(x: 110, y: 90))
        editor.mouseUp(at: CGPoint(x: 110, y: 90))
        XCTAssertEqual(editor.selected?.frame, CGRect(x: 10, y: 10, width: 100, height: 80))

        // ⇧ keeps it square.
        _ = editor.mouseDown(at: CGPoint(x: 110, y: 90), crop: crop, cropHit: .inside)
        editor.mouseDragged(to: CGPoint(x: 50, y: 200), shift: true)
        editor.mouseUp(at: CGPoint(x: 50, y: 200))
        XCTAssertEqual(editor.selected?.frame, CGRect(x: 10, y: 10, width: 190, height: 190))
        XCTAssertEqual(editor.document.undoDepth, 3)
    }

    func testCountersHaveNoHandles() {
        var editor = self.editor(with: .counter)
        draw(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        _ = editor.mouseDown(at: CGPoint(x: 50, y: 50), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 50, y: 50))
        XCTAssertNotNil(editor.selected)
        XCTAssertTrue(editor.selectionHandles.isEmpty)
    }

    func testStyleChangesApplyToTheSelection() {
        var editor = self.editor(with: .rect)
        editor.setColor(.green)
        editor.setWidth(.thin)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        XCTAssertEqual(editor.document.annotations[0].style, ScreenshotAnnotationStyle(color: .green, width: .thin))
        XCTAssertEqual(editor.document.undoDepth, 1, "Nothing selected, nothing changed")

        _ = editor.mouseDown(at: CGPoint(x: 10, y: 25), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 10, y: 25))
        editor.setColor(.white)
        editor.setWidth(.thick)
        XCTAssertEqual(editor.selected?.style, ScreenshotAnnotationStyle(color: .white, width: .thick))
        XCTAssertEqual(editor.document.undoDepth, 3)
    }

    func testDeleteNudgeAndUndoRedo() {
        var editor = self.editor(with: .counter)
        draw(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        XCTAssertFalse(editor.deleteSelected(), "Nothing selected")
        XCTAssertFalse(editor.nudgeSelected(by: CGSize(width: 1, height: 0)))
        _ = editor.mouseDown(at: CGPoint(x: 50, y: 50), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 50, y: 50))

        XCTAssertTrue(editor.nudgeSelected(by: CGSize(width: 10, height: -5)))
        XCTAssertEqual(editor.selected?.kind, .counter(center: CGPoint(x: 60, y: 45)))
        XCTAssertTrue(editor.deleteSelected())
        XCTAssertTrue(editor.document.isEmpty)
        XCTAssertNil(editor.selectedID)

        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document.annotations.count, 1)
        XCTAssertTrue(editor.redo())
        XCTAssertTrue(editor.document.isEmpty)
        XCTAssertTrue(editor.undo())
        _ = editor.mouseDown(at: CGPoint(x: 60, y: 45), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 60, y: 45))
        XCTAssertTrue(editor.undo(), "Undoes the nudge; the counter stays selected")
        XCTAssertNotNil(editor.selectedID)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.selectedID, "The selection went with the counter")
        XCTAssertFalse(editor.undo())
        XCTAssertTrue(editor.redo())
        XCTAssertTrue(editor.redo())
        XCTAssertTrue(editor.redo())
        XCTAssertFalse(editor.redo())
    }

    func testCommandsWaitForTheGestureToEnd() {
        var editor = self.editor(with: .counter)
        draw(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        _ = editor.mouseDown(at: CGPoint(x: 50, y: 50), crop: crop, cropHit: .inside)
        XCTAssertTrue(editor.isDragging)
        XCTAssertFalse(editor.deleteSelected())
        XCTAssertFalse(editor.nudgeSelected(by: CGSize(width: 1, height: 1)))
        XCTAssertFalse(editor.undo())
        XCTAssertFalse(editor.redo())
        editor.mouseUp(at: CGPoint(x: 50, y: 50))
        editor.deselect()
        XCTAssertNil(editor.selected)
    }

    // MARK: Text

    func testTypingAddsTextInTheCurrentStyle() {
        var editor = self.editor(with: .text)
        editor.setWidth(.thick)
        editor.setColor(.blue)
        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 20, y: 30), crop: crop, cropHit: .inside),
                       .beginText(at: CGPoint(x: 20, y: 30)))
        XCTAssertFalse(editor.isDragging)

        editor.commitText("   ", at: CGPoint(x: 20, y: 30))
        XCTAssertTrue(editor.document.isEmpty, "Blank text is dropped")
        editor.commitText("Peak in Sept", at: CGPoint(x: 20, y: 30))
        let text = editor.document.annotations[0]
        XCTAssertEqual(text.kind, .text(origin: CGPoint(x: 20, y: 30), "Peak in Sept", fontSize: 24))
        XCTAssertEqual(text.style.color, .blue)
    }

    func testDoubleClickEditsTextAndEmptyingItRemovesIt() {
        var editor = self.editor(with: .text)
        editor.commitText("Draft", at: CGPoint(x: 20, y: 30))
        let id = editor.document.annotations[0].id

        XCTAssertEqual(editor.mouseDown(at: CGPoint(x: 25, y: 35), clickCount: 2, crop: crop, cropHit: .inside),
                       .editText(id))
        XCTAssertEqual(editor.editingTextID, id)
        XCTAssertTrue(editor.visibleAnnotations.isEmpty, "The field shows instead")
        XCTAssertTrue(editor.selectionHandles.isEmpty)
        editor.commitText("Final", at: .zero)
        XCTAssertEqual(editor.document.annotations[0].kind, .text(origin: CGPoint(x: 20, y: 30), "Final", fontSize: 18))
        XCTAssertNil(editor.editingTextID)

        _ = editor.mouseDown(at: CGPoint(x: 25, y: 35), clickCount: 2, crop: crop, cropHit: .inside)
        editor.cancelText()
        XCTAssertEqual(editor.visibleAnnotations.count, 1, "Cancelling keeps it as it was")

        _ = editor.mouseDown(at: CGPoint(x: 25, y: 35), clickCount: 2, crop: crop, cropHit: .inside)
        editor.commitText("", at: .zero)
        XCTAssertTrue(editor.document.isEmpty)
        XCTAssertNil(editor.selectedID)
    }

    func testResizingTextScalesTheFontAndWidthChangesSetIt() throws {
        var editor = self.editor(with: .text)
        editor.commitText("Hello", at: CGPoint(x: 20, y: 30))
        _ = editor.mouseDown(at: CGPoint(x: 25, y: 35), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 25, y: 35))
        editor.setWidth(.thin)
        guard case let .text(_, _, fontSize)? = editor.selected?.kind else { return XCTFail("No text") }
        XCTAssertEqual(fontSize, 14)

        let frame = try XCTUnwrap(editor.selected?.frame)
        _ = editor.mouseDown(at: CGPoint(x: frame.maxX, y: frame.maxY), crop: crop, cropHit: .inside)
        editor.mouseDragged(to: CGPoint(x: frame.minX + frame.width * 2, y: frame.minY + frame.height * 2))
        editor.mouseUp(at: .zero)
        guard case let .text(origin, _, scaled)? = editor.selected?.kind else { return XCTFail("No text") }
        XCTAssertEqual(origin, CGPoint(x: 20, y: 30))
        XCTAssertEqual(scaled, 28, accuracy: 0.01)
    }

    func testBrushWidthFollowsTheSizeOfASelectedBrushMosaic() {
        var editor = self.editor(with: .mosaic)
        editor.setMosaicShape(.brush)
        draw(&editor, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 100))
        _ = editor.mouseDown(at: CGPoint(x: 120, y: 100), crop: crop, cropHit: .inside)
        editor.mouseUp(at: CGPoint(x: 120, y: 100))

        editor.setWidth(.thin)
        guard case let .brush(_, width)? = editor.selected?.mosaic?.shape else { return XCTFail("No brush") }
        XCTAssertEqual(width, 16)
    }
}
