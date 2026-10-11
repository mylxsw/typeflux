import CoreGraphics
@testable import Typeflux
import XCTest

/// Each tool's own style, its storage, the line tool and the fill, dash and corner options.
final class ScreenshotToolStylesTests: XCTestCase {
    private typealias Style = ScreenshotAnnotationStyle
    private typealias Color = ScreenshotAnnotationStyle.Color
    private let crop = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func draw(_ editor: inout ScreenshotAnnotationEditor, from start: CGPoint, to end: CGPoint,
                      shift: Bool = false) {
        _ = editor.mouseDown(at: start, crop: crop, cropHit: .inside)
        editor.mouseDragged(to: end, shift: shift)
        editor.mouseUp(at: end, shift: shift)
    }

    private func select(_ editor: inout ScreenshotAnnotationEditor, at point: CGPoint) {
        _ = editor.mouseDown(at: point, crop: crop, cropHit: .inside)
        editor.mouseUp(at: point)
    }

    // MARK: Tool styles

    func testEachToolStartsWithItsOwnStyle() {
        let styles = ScreenshotToolStyles()
        XCTAssertEqual(styles[.highlighter].color, .yellow)
        XCTAssertEqual(styles[.highlighter].size, 18)
        XCTAssertEqual(styles[.text].size, 20)
        XCTAssertEqual(styles[.counter].size, 24)
        XCTAssertEqual(styles[.mosaic].color, .black, "Solid mosaics are dark")
        XCTAssertEqual(styles[.rect], Style(color: .red, size: 4))
        for tool in ScreenshotAnnotationTool.allCases {
            XCTAssertTrue(tool.sizeRange.contains(tool.defaultStyle.size), "\(tool)")
            XCTAssertGreaterThan(tool.sizeStep, 0)
        }
        XCTAssertFalse(ScreenshotAnnotationTool.mosaic.usesColor)
        XCTAssertTrue(ScreenshotAnnotationTool.line.usesColor)
    }

    func testStylesAreClampedIntoRange() {
        var styles = ScreenshotToolStyles()
        styles[.pen] = Style(opacity: 0, size: 100, cornerRadius: -3)
        XCTAssertEqual(styles[.pen].size, 16)
        XCTAssertEqual(styles[.pen].opacity, 0.2)
        XCTAssertEqual(styles[.pen].cornerRadius, 0)
        styles[.text].size = 2
        XCTAssertEqual(styles[.text].size, 10)
        XCTAssertEqual(ScreenshotToolStyles.clamp(.nan, to: 1...4), 1)
        XCTAssertEqual(styles[.rect], Style(color: .red, size: 4), "Other tools keep theirs")
    }

    func testRecentColorsAreMostRecentFirstWithoutRepeats() {
        var styles = ScreenshotToolStyles()
        for color in [Color.red, .blue, .red, .green, .pink, .teal, .white] { styles.noteRecent(color) }
        XCTAssertEqual(styles.recentColors, [.white, .teal, .pink, .green, .red])
    }

    func testToolStylesRoundTripAndToleratePartialData() throws {
        var styles = ScreenshotToolStyles()
        styles[.arrow] = Style(color: Color(hex: 0x336699), opacity: 0.6, size: 7, dash: .dashed)
        styles[.rect].fill = .soft
        styles[.rect].cornerRadius = 8
        styles.mosaicEffect = .blur
        styles.mosaicStrength = .high
        styles.mosaicShape = .brush
        styles.noteRecent(.purple)
        let data = try JSONEncoder().encode(styles)
        XCTAssertEqual(try JSONDecoder().decode(ScreenshotToolStyles.self, from: data), styles)

        // An older or newer version: unknown tools and fields are skipped, missing ones defaulted.
        let partial = Data("""
        {"styles": {"pen": {"size": 9}, "lasso": {"size": 3}, "rect": {"color": {"red": 0, "green": 1, "blue": 0},
         "fill": "sparkles"}}, "mosaicEffect": "swirl"}
        """.utf8)
        let decoded = try JSONDecoder().decode(ScreenshotToolStyles.self, from: partial)
        XCTAssertEqual(decoded[.pen], Style(color: .red, size: 9))
        XCTAssertEqual(decoded[.rect].color, Color(red: 0, green: 1, blue: 0))
        XCTAssertEqual(decoded[.rect].fill, .stroke)
        XCTAssertEqual(decoded.mosaicEffect, .pixelate)
        XCTAssertEqual(decoded.recentColors, [])
    }

    @MainActor
    func testTheStoreKeepsStylesInUserDefaults() throws {
        let suite = "ScreenshotToolStylesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ScreenshotToolStyleStore(defaults: defaults)
        XCTAssertEqual(store.styles, ScreenshotToolStyles())
        store.styles[.pen].color = .teal
        XCTAssertNotNil(defaults.string(forKey: ScreenshotToolStyleStore.defaultsKey))
        XCTAssertEqual(ScreenshotToolStyleStore(defaults: defaults).styles[.pen].color, .teal)

        defaults.set("not json", forKey: ScreenshotToolStyleStore.defaultsKey)
        XCTAssertEqual(ScreenshotToolStyleStore(defaults: defaults).styles, ScreenshotToolStyles(),
                       "Unreadable styles fall back to the defaults")
        let memory = ScreenshotToolStyleStore()
        memory.styles[.pen].size = 9
        XCTAssertEqual(memory.styles[.pen].size, 9)
    }

    func testStylesDecodeWithMissingFields() throws {
        let style = try JSONDecoder().decode(Style.self, from: Data(#"{"size": 7, "dash": "dashed"}"#.utf8))
        XCTAssertEqual(style, Style(size: 7, dash: .dashed))
        let full = Style(color: .pink, opacity: 0.5, size: 3, dash: .dashed, fill: .solid, cornerRadius: 6)
        XCTAssertEqual(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(full)), full)
    }

    // MARK: Editor

    func testTheEditorDrawsWithEachToolsStyle() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.highlighter)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10))
        editor.selectTool(.pen)
        editor.setColor(.blue)
        draw(&editor, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 60, y: 50))
        editor.selectTool(.highlighter)
        XCTAssertEqual(editor.style.color, .yellow, "The pen's color stays with the pen")
        XCTAssertEqual(editor.document.annotations.map(\.style.color), [.yellow, .blue])
        XCTAssertEqual(editor.document.annotations.map(\.style.size), [18, 4])
    }

    func testTheEditorStartsFromStoredStyles() {
        var stored = ScreenshotToolStyles()
        stored[.rect].color = .purple
        stored.mosaicShape = .brush
        let editor = ScreenshotAnnotationEditor(toolStyles: stored)
        XCTAssertEqual(editor.toolStyles[.rect].color, .purple)
        XCTAssertEqual(editor.mosaicShape, .brush)
    }

    func testLinesDrawSnapAndAreKeptOnlyWhenLongEnough() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.line)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 14), shift: true)
        XCTAssertEqual(editor.document.annotations.first?.kind.roundedKind,
                       .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 10)), "⇧ snaps to 0°")
        draw(&editor, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 201, y: 201))
        XCTAssertEqual(editor.document.annotations.count, 1, "A click is not a line")
    }

    func testShapeOptionsChangeTheToolOrTheSelectedShape() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.rect)
        editor.setFill(.solid)
        editor.setDash(.dashed)
        editor.setCornerRadius(10)
        editor.setOpacity(0.5)
        XCTAssertEqual(editor.toolStyles[.rect], Style(opacity: 0.5, dash: .dashed, fill: .solid, cornerRadius: 10))
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        XCTAssertEqual(editor.document.annotations[0].style.fill, .solid)

        // A filled box is picked anywhere inside it.
        select(&editor, at: CGPoint(x: 60, y: 35))
        XCTAssertNotNil(editor.selected)
        editor.setFill(.stroke)
        editor.setCornerRadius(99)
        XCTAssertEqual(editor.selected?.style.fill, .stroke)
        XCTAssertEqual(editor.selected?.style.cornerRadius, 24, "Clamped")
        XCTAssertEqual(editor.toolStyles[.rect].fill, .solid)
        XCTAssertEqual(editor.document.undoDepth, 3)
    }

    func testASliderDragIsOneUndoStep() {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.pen)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        select(&editor, at: CGPoint(x: 35, y: 35))
        XCTAssertEqual(editor.document.undoDepth, 1)

        editor.apply(.styleChange(began: true))
        for size in stride(from: 5, through: 12, by: 1) { editor.apply(.size(CGFloat(size))) }
        editor.apply(.opacity(0.7))
        editor.apply(.styleChange(began: false))
        XCTAssertEqual(editor.selected?.style.size, 12)
        XCTAssertEqual(editor.document.undoDepth, 2)
        editor.endStyleChange()
        XCTAssertEqual(editor.document.undoDepth, 2, "Ending twice records nothing")
        editor.undo()
        XCTAssertEqual(editor.document.annotations[0].style.size, 4)
        XCTAssertEqual(editor.document.annotations[0].style.opacity, 1)
    }

    func testColorAndSizeKeys() {
        var editor = ScreenshotAnnotationEditor()
        XCTAssertFalse(editor.handleStyleKey(ScreenshotAnnotationEditor.colorKeyCodes[1]), "No tool, no style")
        editor.selectTool(.ellipse)
        XCTAssertTrue(editor.handleStyleKey(ScreenshotAnnotationEditor.colorKeyCodes[5]))
        XCTAssertEqual(editor.toolStyles[.ellipse].color, .blue)
        XCTAssertTrue(editor.handleStyleKey(ScreenshotAnnotationEditor.colorKeyCodes[9]))
        XCTAssertEqual(editor.toolStyles[.ellipse].color, .black, "0 is the tenth color")
        XCTAssertTrue(editor.handleStyleKey(ScreenshotAnnotationEditor.largerKeyCode))
        XCTAssertEqual(editor.toolStyles[.ellipse].size, 5)
        for _ in 0 ..< 30 { _ = editor.handleStyleKey(ScreenshotAnnotationEditor.smallerKeyCode) }
        XCTAssertEqual(editor.toolStyles[.ellipse].size, 1, "Stops at the smallest")
        XCTAssertFalse(editor.handleStyleKey(99))

        editor.selectTool(.text)
        XCTAssertTrue(editor.handleStyleKey(ScreenshotAnnotationEditor.largerKeyCode))
        XCTAssertEqual(editor.toolStyles[.text].size, 22, "Text steps by two")

        editor.selectTool(.mosaic)
        XCTAssertFalse(editor.offersColor)
        XCTAssertFalse(editor.handleStyleKey(ScreenshotAnnotationEditor.colorKeyCodes[0]), "A pixelated mosaic has no color")
        editor.setMosaicEffect(.solid)
        XCTAssertTrue(editor.offersColor)
        XCTAssertTrue(editor.handleStyleKey(ScreenshotAnnotationEditor.colorKeyCodes[2]))
        XCTAssertEqual(editor.toolStyles[.mosaic].color, .yellow)
    }

    func testOptionsFollowTheSelectedAnnotation() {
        var editor = ScreenshotAnnotationEditor()
        XCTAssertNil(editor.optionsTool)
        XCTAssertNil(editor.shownStyle)
        XCTAssertNil(editor.shownSize)
        editor.selectTool(.line)
        draw(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 10))
        editor.selectTool(.counter)
        XCTAssertEqual(editor.optionsTool, .counter)
        XCTAssertEqual(editor.shownSize, 24)
        select(&editor, at: CGPoint(x: 50, y: 10))
        XCTAssertEqual(editor.optionsTool, .line, "The selected line's options")
        XCTAssertEqual(editor.shownSize, 4)
        editor.setSize(40)
        XCTAssertEqual(editor.selected?.style.size, 16, "Clamped to the line's range")
    }

    func testViewActionsAreLeftToTheView() {
        var editor = ScreenshotAnnotationEditor()
        for action: ScreenshotEditorToolbarModel.Action in [.toggleColorPanel, .pickColor, .cancel, .save, .copy,
                                                             .scrollCapture, .followUp(.askAI)] {
            XCTAssertFalse(editor.apply(action), "\(action)")
        }
        XCTAssertTrue(editor.apply(.tool(.rect)))
        XCTAssertTrue(editor.apply(.dash(.dashed)))
        XCTAssertTrue(editor.apply(.fill(.soft)))
        XCTAssertTrue(editor.apply(.cornerRadius(3)))
        XCTAssertTrue(editor.apply(.color(.pink)))
        XCTAssertTrue(editor.apply(.mosaicShape(.brush)))
        XCTAssertTrue(editor.apply(.mosaicEffect(.blur)))
        XCTAssertTrue(editor.apply(.mosaicStrength(.low)))
        XCTAssertTrue(editor.apply(.undo))
        XCTAssertTrue(editor.apply(.redo))
        XCTAssertEqual(editor.toolStyles[.rect], Style(color: .pink, dash: .dashed, fill: .soft, cornerRadius: 3))
    }

    func testSuggestedMosaicsUseTheMosaicStyle() {
        var editor = ScreenshotAnnotationEditor()
        editor.setMosaicEffect(.solid)
        editor.addMosaics(over: [CGRect(x: 0, y: 0, width: 40, height: 10)])
        XCTAssertEqual(editor.document.annotations[0].style.color, .black)
        XCTAssertEqual(editor.document.annotations[0].mosaic?.effect, .solid)
    }

    // MARK: Geometry

    func testLineGeometry() {
        let line = ScreenshotAnnotation(kind: .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)))
        XCTAssertEqual(line.frame, CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertTrue(line.contains(CGPoint(x: 30, y: 25)))
        XCTAssertFalse(line.contains(CGPoint(x: 10, y: 40)))
        XCTAssertEqual(line.offsetBy(dx: 5, dy: -5).kind, .line(from: CGPoint(x: 15, y: 5), to: CGPoint(x: 55, y: 35)))
        XCTAssertEqual(line.resized(from: line.frame, to: CGRect(x: 0, y: 0, width: 80, height: 60)).kind,
                       .line(from: .zero, to: CGPoint(x: 80, y: 60)))
        XCTAssertEqual(line.tool, .line)
        XCTAssertTrue(line.isResizable)
        XCTAssertNil(line.shapePath)
    }

    func testShapePathsRoundCornersAndFilledShapesAreHitInside() {
        var box = ScreenshotAnnotation(kind: .rect(CGRect(x: 0, y: 0, width: 40, height: 20)),
                                       style: Style(cornerRadius: 50))
        let path = box.shapePath
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.contains(CGPoint(x: 1, y: 1)) ?? true, "Corners are rounded, at most half the height")
        XCTAssertFalse(box.contains(CGPoint(x: 20, y: 10)), "An outline is not hit inside")
        box.style.fill = .soft
        XCTAssertTrue(box.contains(CGPoint(x: 20, y: 10)))
        let ellipse = ScreenshotAnnotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 40, height: 20)),
                                           style: Style(fill: .solid))
        XCTAssertTrue(ellipse.contains(CGPoint(x: 20, y: 10)))
        XCTAssertFalse(ellipse.contains(CGPoint(x: 80, y: 80)))
        XCTAssertEqual(Style.dashLengths(lineWidth: 1), [4, 4])
        XCTAssertEqual(Style.dashLengths(lineWidth: 4), [12, 9.6])
    }

    func testTheSizeOfAnAnnotationIsWhatItsSliderChanges() {
        var text = ScreenshotAnnotation(kind: .text(origin: .zero, "Hi", fontSize: 30))
        XCTAssertEqual(text.size, 30)
        text.size = 12
        XCTAssertEqual(text.kind, .text(origin: .zero, "Hi", fontSize: 12))
        XCTAssertEqual(text.style.size, 12)
        var brush = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .brush([.zero], width: 20))))
        XCTAssertEqual(brush.size, 20)
        brush.size = 30
        XCTAssertEqual(brush.mosaic?.shape, .brush([.zero], width: 30))
        var box = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(.zero))), style: Style(size: 8))
        XCTAssertEqual(box.size, 8)
        box.size = 9
        XCTAssertEqual(box.style.size, 9)
        var pen = ScreenshotAnnotation(kind: .path([.zero]))
        pen.size = 7
        XCTAssertEqual(pen.style.size, 7)
        XCTAssertEqual(pen.tool, .pen)
    }
}

private extension ScreenshotAnnotation.Kind {
    /// Line ends rounded to whole points, for comparing snapped lines.
    var roundedKind: ScreenshotAnnotation.Kind {
        guard case let .line(from, to) = self else { return self }
        return .line(from: CGPoint(x: from.x.rounded(), y: from.y.rounded()),
                     to: CGPoint(x: to.x.rounded(), y: to.y.rounded()))
    }
}
