import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// Arrow heads and paths, pen smoothing, highlighter strokes, text fonts and styles, and counter labels.
@MainActor
final class ScreenshotToolOptionsTests: XCTestCase {
    private typealias Style = ScreenshotAnnotationStyle
    private let crop = CGRect(x: 0, y: 0, width: 400, height: 300)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func draw(_ editor: inout ScreenshotAnnotationEditor, _ points: [CGPoint], shift: Bool = false) {
        _ = editor.mouseDown(at: points[0], crop: crop, cropHit: .inside)
        for point in points.dropFirst() { editor.mouseDragged(to: point, shift: shift) }
        editor.mouseUp(at: points.last ?? points[0], shift: shift)
    }

    private func select(_ editor: inout ScreenshotAnnotationEditor, at point: CGPoint) {
        _ = editor.mouseDown(at: point, crop: crop, cropHit: .inside)
        editor.mouseUp(at: point)
    }

    /// Renders annotations over a mid-gray 1× display and returns its RGBA pixels.
    private func render(_ annotations: [ScreenshotAnnotation], width: Int = 200,
                        height: Int = 120) throws -> ScreenshotMosaicEffects.Pixels {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: width, height: height), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: width, height: height))
        let image = try ScreenshotRenderer.render(display, crop: display.frame, annotations: annotations)
        return try XCTUnwrap(ScreenshotMosaicEffects.Pixels(image, space: Self.sRGB))
    }

    private func rgb(_ pixels: ScreenshotMosaicEffects.Pixels, _ x: Int, _ y: Int) -> [Int] {
        let offset = (y * pixels.width + x) * 4
        return pixels.bytes[offset ..< offset + 3].map(Int.init)
    }

    private func isGray(_ value: [Int]) -> Bool {
        value.allSatisfy { abs($0 - value[0]) < 6 } && abs(value[0] - 128) < 30
    }

    // MARK: Arrows

    func testArrowPathsBendAndPointTheirHeads() throws {
        let from = CGPoint(x: 0, y: 0), to = CGPoint(x: 100, y: 0)
        var style = Style()
        XCTAssertNil(ScreenshotAnnotation.arrowBendPoint(from: from, to: to, style: style))
        style.arrowPath = .curve
        style.arrowBend = 0.3
        let control = try XCTUnwrap(ScreenshotAnnotation.arrowBendPoint(from: from, to: to, style: style))
        XCTAssertEqual(control.x, 50, accuracy: 0.01)
        XCTAssertEqual(control.y, 30, accuracy: 0.01, "Bowed to the right of the direction of travel")
        let directions = ScreenshotAnnotation.arrowDirections(from: from, to: to, style: style)
        XCTAssertGreaterThan(directions.end.x, 0)
        XCTAssertLessThan(directions.end.y, 0, "Arrives coming up from the bow")

        let curved = ScreenshotAnnotation(kind: .arrow(from: from, to: to), style: style)
        let handle = try XCTUnwrap(curved.bendHandle)
        XCTAssertEqual(handle.y, 15, accuracy: 0.01, "The handle sits on the curve")
        XCTAssertTrue(curved.contains(handle))
        XCTAssertFalse(curved.contains(CGPoint(x: 50, y: -10)))
        XCTAssertGreaterThan(curved.frame.maxY, 10, "The frame covers the bow")
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: CGPoint(x: 50, y: -20), from: from, to: to, path: .curve),
                       -0.4, accuracy: 0.001)
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: CGPoint(x: 50, y: 900), from: from, to: to, path: .curve),
                       2, "Limited")
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: .zero, from: from, to: from, path: .curve), 0)
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: .zero, from: from, to: to, path: .straight), 0)

        style.arrowPath = .elbow
        style.arrowBend = 1
        let down = CGPoint(x: 100, y: 60)
        XCTAssertEqual(ScreenshotAnnotation.arrowBendPoint(from: from, to: down, style: style), CGPoint(x: 100, y: 0))
        style.arrowBend = -1
        XCTAssertEqual(ScreenshotAnnotation.arrowBendPoint(from: from, to: down, style: style), CGPoint(x: 0, y: 60))
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: CGPoint(x: 90, y: 5), from: from, to: down, path: .elbow), 1)
        XCTAssertEqual(ScreenshotAnnotation.arrowBend(through: CGPoint(x: 5, y: 50), from: from, to: down, path: .elbow), -1)
        let elbow = ScreenshotAnnotation(kind: .arrow(from: from, to: down), style: style)
        XCTAssertEqual(elbow.bendHandle, CGPoint(x: 0, y: 60))
        XCTAssertTrue(elbow.contains(CGPoint(x: 0, y: 30)))
        XCTAssertNil(ScreenshotAnnotation(kind: .arrow(from: from, to: to)).bendHandle)
    }

    func testDrawingElbowsTurnsTheWayTheDragWentAndCurvesBowByDefault() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.arrow)
        editor.setArrowPath(.elbow)
        draw(&editor, [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 40)])
        draw(&editor, [CGPoint(x: 10, y: 100), CGPoint(x: 30, y: 250)])
        XCTAssertEqual(editor.document.annotations.map(\.style.arrowBend), [1, -1])
        editor.setArrowPath(.curve)
        draw(&editor, [CGPoint(x: 300, y: 10), CGPoint(x: 390, y: 10)])
        XCTAssertEqual(editor.document.annotations.last?.style.arrowBend, Style.defaultCurveBend)
        XCTAssertTrue(editor.toolStyles[.arrow].outlined, "Arrows are outlined by default")
    }

    func testTheBendHandleBendsTheSelectedArrowInOneUndoStep() throws {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.arrow)
        editor.setArrowPath(.curve)
        draw(&editor, [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)])
        let curve = try XCTUnwrap(editor.document.annotations.first)
        select(&editor, at: try XCTUnwrap(curve.bendHandle))
        let handle = try XCTUnwrap(editor.bendHandle)

        XCTAssertEqual(editor.mouseDown(at: handle, crop: crop, cropHit: .inside), .handled)
        editor.mouseDragged(to: CGPoint(x: 200, y: 80))
        editor.mouseDragged(to: CGPoint(x: 200, y: 60))
        editor.mouseUp(at: CGPoint(x: 200, y: 60))
        XCTAssertEqual(try XCTUnwrap(editor.selected?.style.arrowBend), -0.4, accuracy: 0.001)
        XCTAssertEqual(editor.document.undoDepth, 2)

        // Paths can change on the selected arrow; going straight drops the bend.
        editor.setArrowPath(.straight)
        XCTAssertEqual(editor.selected?.style.arrowBend, 0)
        XCTAssertNil(editor.bendHandle)
        editor.setArrowPath(.curve)
        XCTAssertEqual(editor.selected?.style.arrowBend, Style.defaultCurveBend)
        editor.setArrowPath(.elbow)
        XCTAssertEqual(editor.selected?.style.arrowBend, 1)
        editor.setArrowHead(.double)
        editor.setOutlined(false)
        XCTAssertEqual(editor.selected?.style.arrowHead, .double)
        XCTAssertEqual(editor.selected?.style.outlined, false)
        XCTAssertEqual(editor.toolStyles[.arrow].arrowHead, .filled, "The tool keeps its own")
    }

    func testArrowsRenderTheirOutlineAndHeads() throws {
        var outlined = Style(color: .blue, size: 4)
        outlined.outlined = true
        let pixels = try render([ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 20, y: 60),
                                                                   to: CGPoint(x: 180, y: 60)), style: outlined)])
        let shaft = rgb(pixels, 100, 60)
        XCTAssertGreaterThan(shaft[2], 200, "Blue shaft")
        let edge = rgb(pixels, 100, 64)
        XCTAssertTrue(edge.allSatisfy { $0 > 230 }, "White outline beside the shaft: \(edge)")

        var double = Style(color: .red, size: 4)
        double.arrowHead = .double
        double.arrowPath = .elbow
        double.arrowBend = 1
        let elbow = try render([ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 20, y: 20),
                                                                  to: CGPoint(x: 180, y: 100)), style: double)])
        XCTAssertFalse(isGray(rgb(elbow, 180, 60)), "The elbow turns down at the far side")
        XCTAssertTrue(isGray(rgb(elbow, 20, 60)), "Not at the near side")
        XCTAssertFalse(isGray(rgb(elbow, 28, 23)), "A head at the start too")

        var open = Style(color: .red, size: 4)
        open.arrowHead = .open
        open.arrowPath = .curve
        open.arrowBend = 0.3
        let curve = try render([ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 20, y: 30),
                                                                  to: CGPoint(x: 180, y: 30)), style: open)])
        XCTAssertFalse(isGray(rgb(curve, 100, 54)), "The curve bows down")
        XCTAssertTrue(isGray(rgb(curve, 100, 30)), "Not along the chord")
    }

    // MARK: Pen and highlighter

    func testSmoothingDropsTheShakeAndKeepsTheEnds() {
        let shaky = (0 ... 40).map { CGPoint(x: CGFloat($0) * 5, y: $0 % 2 == 0 ? 0.6 : -0.6) }
        let simplified = ScreenshotStrokeSmoothing.simplified(shaky, tolerance: 1.5)
        XCTAssertEqual(simplified, [shaky[0], shaky[40]], "Shake within the tolerance is dropped")
        XCTAssertEqual(ScreenshotStrokeSmoothing.simplified([.zero, CGPoint(x: 1, y: 1)], tolerance: 1).count, 2)

        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 50)]
        let smooth = ScreenshotStrokeSmoothing.smoothed(corner)
        XCTAssertEqual(smooth.first, corner.first)
        XCTAssertEqual(smooth.last, corner.last)
        XCTAssertGreaterThan(smooth.count, corner.count, "Curved through the corners")
        XCTAssertEqual(ScreenshotStrokeSmoothing.catmullRom(.zero, CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2),
                                                           CGPoint(x: 3, y: 3), t: 0.5), CGPoint(x: 1.5, y: 1.5))
        XCTAssertEqual(ScreenshotStrokeSmoothing.smoothed([.zero]), [.zero])
    }

    func testThePenSmoothsWhenTheStrokeEndsUnlessSetToRaw() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.pen)
        let wobble = (0 ... 30).map { CGPoint(x: 10 + CGFloat($0) * 4, y: 50 + ($0 % 2 == 0 ? 0.5 : -0.5)) }
        draw(&editor, wobble)
        guard case let .path(smoothed)? = editor.document.annotations.last?.kind else { return XCTFail("No stroke") }
        XCTAssertEqual(smoothed.count, 2)

        editor.setSmoothed(false)
        // Lower down, so the press does not pick up the first stroke.
        draw(&editor, wobble.map { CGPoint(x: $0.x, y: $0.y + 100) })
        guard case let .path(raw)? = editor.document.annotations.last?.kind else { return XCTFail("No stroke") }
        XCTAssertEqual(raw.count, wobble.count)
        select(&editor, at: CGPoint(x: 50, y: 50))
        editor.setSmoothed(true)
        XCTAssertTrue(editor.toolStyles[.pen].smoothed, "Smoothing changes the pen, not the stroke")
        XCTAssertEqual(editor.document.undoDepth, 2)
    }

    func testTheHighlighterDrawsStraightByDefaultAndFreehandWhenAsked() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.highlighter)
        draw(&editor, [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 14), CGPoint(x: 120, y: 12)])
        XCTAssertEqual(editor.document.annotations.last?.kind,
                       .highlight([CGPoint(x: 10, y: 10), CGPoint(x: 120, y: 12)]))
        draw(&editor, [CGPoint(x: 10, y: 60), CGPoint(x: 120, y: 66)], shift: true)
        guard case let .highlight(level)? = editor.document.annotations.last?.kind else { return XCTFail("No stroke") }
        XCTAssertEqual(level.last?.y ?? 0, 60, accuracy: 0.001, "⇧ keeps it level")

        editor.setHighlighterMode(.free)
        draw(&editor, [CGPoint(x: 10, y: 100), CGPoint(x: 50, y: 110), CGPoint(x: 120, y: 100)])
        guard case let .highlight(free)? = editor.document.annotations.last?.kind else { return XCTFail("No stroke") }
        XCTAssertEqual(free.count, 3)
        XCTAssertEqual(editor.toolStyles[.highlighter].highlighterTip, .square)
    }

    func testSquareHighlighterTipsStopAtTheirEnds() throws {
        var square = Style(color: .yellow, size: 20)
        square.highlighterTip = .square
        var round = square
        round.highlighterTip = .round
        let stroke: ScreenshotAnnotation.Kind = .highlight([CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60)])
        XCTAssertTrue(isGray(rgb(try render([ScreenshotAnnotation(kind: stroke, style: square)]), 45, 60)))
        XCTAssertFalse(isGray(rgb(try render([ScreenshotAnnotation(kind: stroke, style: round)]), 45, 60)))
    }

    // MARK: Text

    func testTextFontsUseTheSystemsDesigns() {
        let system = ScreenshotAnnotation.font(size: 20)
        XCTAssertEqual(system.pointSize, 20)
        for family in Style.TextFont.allCases where family != .system {
            let font = ScreenshotAnnotation.font(size: 20, family: family)
            XCTAssertEqual(font.pointSize, 20)
            XCTAssertNotEqual(font.fontName, system.fontName, "\(family)")
        }
        let mono = ScreenshotAnnotation.textSize("iiii", fontSize: 20, font: .mono)
        XCTAssertGreaterThan(mono.width, ScreenshotAnnotation.textSize("iiii", fontSize: 20).width)
    }

    func testTextOnAColorIsPaddedAndDrawnOnABlock() throws {
        var style = Style(color: .blue, size: 20)
        style.textStyle = .background
        let text = ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 40, y: 40), "Hi", fontSize: 20), style: style)
        let plain = ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 40, y: 40), "Hi", fontSize: 20))
        let padding = ScreenshotAnnotation.textPadding(fontSize: 20)
        XCTAssertEqual(text.frame, plain.frame.insetBy(dx: -padding.width, dy: -padding.height))
        let pixels = try render([text])
        let corner = rgb(pixels, Int(text.frame.minX) + 4, Int(text.frame.midY))
        XCTAssertGreaterThan(corner[2], 200, "Blue block behind the text: \(corner)")

        style.textStyle = .outline
        let outlined = try render([ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 20, y: 20), "HHHH",
                                                                    fontSize: 60), style: style)], width: 300)
        var white = 0
        for x in 20 ..< 280 where rgb(outlined, x, 50).allSatisfy({ $0 > 220 }) { white += 1 }
        XCTAssertGreaterThan(white, 0, "White letters inside the outline")
    }

    func testFontAndTextStyleChangeTheSelectedText() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.text)
        XCTAssertEqual(editor.style.textStyle, .background, "Text starts on a color")
        editor.setFont(.rounded)
        editor.commitText("Note", at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(editor.document.annotations[0].style.font, .rounded)
        select(&editor, at: CGPoint(x: 30, y: 30))
        editor.setTextStyle(.outline)
        editor.setFont(.mono)
        XCTAssertEqual(editor.selected?.style.textStyle, .outline)
        XCTAssertEqual(editor.selected?.style.font, .mono)
        XCTAssertEqual(editor.toolStyles[.text].font, .rounded)
    }

    // MARK: Counters

    func testCounterLabelsCountInNumbersOrLetters() {
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(3, as: .number), "3")
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(1, as: .letter), "A")
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(26, as: .letter), "Z")
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(27, as: .letter), "AA")
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(53, as: .letter), "BA")
        XCTAssertEqual(ScreenshotAnnotation.counterLabel(0, as: .letter), "0")
        XCTAssertEqual(ScreenshotEditorToolbarModel.sample(for: .letter), "A B C")
    }

    func testTheStartAppliesToEveryCounterInOneUndoStep() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.counter)
        editor.setCounterStart(5)
        draw(&editor, [CGPoint(x: 20, y: 20)])
        draw(&editor, [CGPoint(x: 80, y: 20)])
        XCTAssertEqual(editor.document.annotations.map { editor.document.counterNumber(of: $0.id) }, [5, 6])
        XCTAssertEqual(editor.counterStart, 5)

        editor.setCounterStart(1)
        XCTAssertEqual(editor.document.annotations.map { editor.document.counterNumber(of: $0.id) }, [1, 2])
        XCTAssertEqual(editor.document.undoDepth, 3)
        editor.setCounterStart(1)
        XCTAssertEqual(editor.document.undoDepth, 3, "No change, no step")
        editor.setCounterStart(500)
        XCTAssertEqual(editor.counterStart, 99)
        editor.undo()
        XCTAssertEqual(editor.counterStart, 1)

        editor.setCounterLabel(.letter)
        XCTAssertEqual(editor.toolStyles[.counter].counterLabel, .letter)
    }

    func testBubbleCountersStayPutAndPointWhereTheDragWent() throws {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.counter)
        editor.setCounterShape(.bubble)
        draw(&editor, [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 160)])
        let bubble = try XCTUnwrap(editor.document.annotations.first)
        XCTAssertEqual(bubble.kind, .counter(center: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(bubble.style.counterAngle, .pi / 2, accuracy: 0.001, "Pointing down")

        editor.setCounterShape(.circle)
        draw(&editor, [CGPoint(x: 200, y: 100), CGPoint(x: 220, y: 120)])
        XCTAssertEqual(editor.document.annotations.last?.kind, .counter(center: CGPoint(x: 220, y: 120)),
                       "A circle follows the pointer")

        let tail = ScreenshotRenderer.counterTail(in: CGRect(x: 0, y: 0, width: 20, height: 20), angle: 0)
        XCTAssertTrue(tail.contains(CGPoint(x: 20, y: 10)))
        XCTAssertFalse(tail.contains(CGPoint(x: 4, y: 10)))
        let pixels = try render([ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 100, y: 60)),
                                                      style: bubble.style)])
        XCTAssertFalse(isGray(rgb(pixels, 100, 60 + 18)), "The point reaches below the circle")
    }

    func testCounterLettersRender() throws {
        var style = Style(color: .red, size: 30)
        style.counterLabel = .letter
        style.counterStart = 27
        let counter = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 100, y: 60)), style: style)
        XCTAssertEqual(ScreenshotAnnotationDocument(annotations: [counter]).counterNumber(of: counter.id), 27)
        let pixels = try render([counter])
        var white = 0
        for x in 88 ..< 112 where rgb(pixels, x, 60).allSatisfy({ $0 > 180 }) { white += 1 }
        XCTAssertGreaterThan(white, 0, "“AA” in white")
    }

    // MARK: Toolbar and storage

    func testEveryToolsOptionsRenderAndNewActionsApply() {
        func width(_ tool: ScreenshotAnnotationTool, _ change: (inout Style) -> Void = { _ in }) -> CGFloat {
            var state = ScreenshotEditorToolbarModel.State()
            state.showsOptions = true
            state.showsColor = true
            state.tool = tool
            state.optionsTool = tool
            state.style = tool.defaultStyle
            change(&state.style)
            return NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar).fittingSize.width
        }
        for tool in [ScreenshotAnnotationTool.arrow, .pen, .highlighter, .text, .counter] {
            XCTAssertGreaterThan(width(tool), width(.line), "\(tool) has more options than a line")
        }
        for head in Style.ArrowHead.allCases { XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: head).isEmpty) }
        for path in Style.ArrowPath.allCases { XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: path).isEmpty) }
        for shape in Style.CounterShape.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: shape).isEmpty)
        }

        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.arrow)
        for action: ScreenshotEditorToolbarModel.Action in [.arrowHead(.open), .arrowPath(.curve), .outlined(false)] {
            XCTAssertTrue(editor.apply(action))
        }
        editor.selectTool(.pen)
        XCTAssertTrue(editor.apply(.smoothed(false)))
        editor.selectTool(.highlighter)
        XCTAssertTrue(editor.apply(.highlighterMode(.free)))
        XCTAssertTrue(editor.apply(.highlighterTip(.round)))
        editor.selectTool(.text)
        XCTAssertTrue(editor.apply(.font(.serif)))
        XCTAssertTrue(editor.apply(.textStyle(.plain)))
        editor.selectTool(.counter)
        XCTAssertTrue(editor.apply(.counterLabel(.letter)))
        XCTAssertTrue(editor.apply(.counterShape(.bubble)))
        XCTAssertTrue(editor.apply(.counterStart(3)))
        let styles = editor.toolStyles
        XCTAssertEqual(styles[.arrow].arrowHead, .open)
        XCTAssertEqual(styles[.arrow].arrowPath, .curve)
        XCTAssertFalse(styles[.arrow].outlined)
        XCTAssertFalse(styles[.pen].smoothed)
        XCTAssertEqual(styles[.highlighter].highlighterMode, .free)
        XCTAssertEqual(styles[.highlighter].highlighterTip, .round)
        XCTAssertEqual(styles[.text].font, .serif)
        XCTAssertEqual(styles[.text].textStyle, .plain)
        XCTAssertEqual(styles[.counter].counterLabel, .letter)
        XCTAssertEqual(styles[.counter].counterShape, .bubble)
        XCTAssertEqual(styles[.counter].counterStart, 3)
        XCTAssertEqual(ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false,
                                                          isPickingColor: false).counterStart, 3)
    }

    func testNewStyleFieldsRoundTripAndAreClamped() throws {
        var style = Style(color: .teal)
        style.arrowHead = .double
        style.arrowPath = .elbow
        style.arrowBend = -1
        style.outlined = true
        style.smoothed = true
        style.highlighterMode = .straight
        style.highlighterTip = .square
        style.font = .mono
        style.textStyle = .outline
        style.counterLabel = .letter
        style.counterShape = .bubble
        style.counterAngle = 1.2
        style.counterStart = 7
        XCTAssertEqual(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style)), style)

        var wild = Style()
        wild.counterStart = 400
        wild.arrowBend = .infinity
        wild.counterAngle = .nan
        let normalized = ScreenshotToolStyles.normalized(wild, for: .counter)
        XCTAssertEqual(normalized.counterStart, 99)
        XCTAssertEqual(normalized.arrowBend, 0)
        XCTAssertEqual(normalized.counterAngle, Style().counterAngle)
    }
}
