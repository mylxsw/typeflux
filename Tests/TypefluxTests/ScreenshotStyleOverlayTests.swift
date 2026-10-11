import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// The color panel, the eyedropper and the tool styles in the region overlay and the long image editor.
@MainActor
final class ScreenshotStyleOverlayTests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key

    /// A 200 × 100 point display at 1×: its left half red, its right half blue.
    private func makeView(store: ScreenshotToolStyleStore = ScreenshotToolStyleStore())
        -> (ScreenshotOverlayView, () -> [ScreenshotOverlayView.LocalEvent]) {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
                                             image: Self.twoColorImage(width: 200, height: 100))
        let view = ScreenshotOverlayView(display: display, windows: [], toolStyles: store)
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        view.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 190, y: 90))
        view.mouseUp(at: CGPoint(x: 190, y: 90))
        return (view, { events })
    }

    static func twoColorImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    func testTheColorPanelOpensFromTheColorButtonAndClosesOnAChoice() {
        let (view, _) = makeView()
        XCTAssertFalse(view.toolbarModel.state.showsColor, "No tool, no color")
        view.toolbarModel.perform(.tool(.rect))
        XCTAssertTrue(view.toolbarModel.state.showsColor)
        let twoRows = view.toolbar?.frame.height ?? 0

        view.toolbarModel.perform(.toggleColorPanel)
        XCTAssertTrue(view.toolbarModel.state.showsColorPanel)
        XCTAssertGreaterThan(view.toolbar?.frame.height ?? 0, twoRows, "The panel adds a row")
        view.toolbarModel.perform(.opacity(0.6))
        XCTAssertTrue(view.toolbarModel.state.showsColorPanel, "Opacity keeps it open")
        view.toolbarModel.perform(.color(.teal))
        XCTAssertFalse(view.toolbarModel.state.showsColorPanel)
        XCTAssertEqual(view.toolbarModel.state.style.color, .teal)
        XCTAssertEqual(view.toolbarModel.state.style.opacity, 0.6)
        XCTAssertEqual(view.toolbarModel.state.recentColors, [.teal])

        view.toolbarModel.perform(.toggleColorPanel)
        view.toolbarModel.perform(.tool(.mosaic))
        XCTAssertFalse(view.toolbarModel.state.showsColorPanel, "A pixelated mosaic has no color to pick")
    }

    func testTheEyedropperTakesTheColorUnderTheNextClick() {
        let (view, events) = makeView()
        view.toolbarModel.perform(.tool(.pen))
        view.toolbarModel.perform(.toggleColorPanel)
        view.toolbarModel.perform(.pickColor)
        XCTAssertTrue(view.isPickingColor)
        XCTAssertTrue(view.toolbarModel.state.isPickingColor)
        view.pointerMoved(to: CGPoint(x: 150, y: 50))
        XCTAssertTrue(view.showsLoupe, "The loupe helps aim")

        view.mouseDown(at: CGPoint(x: 150, y: 50), clickCount: 1)
        view.mouseUp(at: CGPoint(x: 150, y: 50))
        XCTAssertFalse(view.isPickingColor)
        XCTAssertFalse(view.showsColorPanel)
        XCTAssertEqual(view.editor.toolStyles[.pen].color, ScreenshotAnnotationStyle.Color(hex: 0x0000FF))
        XCTAssertTrue(view.editor.document.isEmpty, "The click picks, it does not draw")

        // Esc puts the eyedropper down without leaving the screenshot.
        view.toolbarModel.perform(.pickColor)
        XCTAssertTrue(view.handleKeyDown(Key.escape, modifiers: []))
        XCTAssertFalse(view.isPickingColor)
        XCTAssertTrue(events().allSatisfy { $0 != .cancelled })
        XCTAssertTrue(view.handleKeyDown(Key.escape, modifiers: []))
        XCTAssertEqual(events().last, .cancelled)
    }

    func testStyleKeysAndTheLineToolInTheOverlay() {
        let (view, _) = makeView()
        XCTAssertTrue(view.handleKeyDown(ScreenshotAnnotationTool.line.keyCode, modifiers: []))
        XCTAssertEqual(view.editor.tool, .line)
        XCTAssertTrue(view.handleKeyDown(ScreenshotAnnotationEditor.colorKeyCodes[3], modifiers: []))
        XCTAssertTrue(view.handleKeyDown(ScreenshotAnnotationEditor.largerKeyCode, modifiers: []))
        XCTAssertEqual(view.toolbarModel.state.style.color, .green)
        XCTAssertEqual(view.toolbarModel.state.size, 5)
        XCTAssertFalse(view.handleKeyDown(ScreenshotAnnotationEditor.colorKeyCodes[3], modifiers: [.command]),
                       "⌘ digits are not colors")
    }

    func testStylesAreKeptForTheNextScreenshot() {
        let store = ScreenshotToolStyleStore()
        let (first, _) = makeView(store: store)
        first.toolbarModel.perform(.tool(.arrow))
        first.toolbarModel.perform(.color(.purple))
        first.toolbarModel.perform(.size(9))
        XCTAssertEqual(store.styles[.arrow].color, .purple)

        let (second, _) = makeView(store: store)
        second.toolbarModel.perform(.tool(.arrow))
        XCTAssertEqual(second.toolbarModel.state.style.color, .purple)
        XCTAssertEqual(second.toolbarModel.state.size, 9)
    }

    func testADisplayThatIsNotMarkedUpNeverOverwritesTheStyles() {
        let store = ScreenshotToolStyleStore()
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 100 }, pointerLocation: { .zero },
                                                     toolStyles: store)
        controller.present(ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 200, height: 100)),
            .init(id: 2, frame: CGRect(x: 200, y: 0, width: 200, height: 100), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 200, height: 100))
        ], windows: [])) { _ in }
        defer { controller.dismiss() }
        let first = controller.views[0], second = controller.views[1]
        first.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        first.mouseDragged(to: CGPoint(x: 150, y: 80))
        first.mouseUp(at: CGPoint(x: 150, y: 80))
        first.toolbarModel.perform(.tool(.rect))
        first.toolbarModel.perform(.color(.purple))
        XCTAssertEqual(store.styles[.rect].color, .purple)

        second.pointerMoved(to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(store.styles[.rect].color, .purple, "The other display's old styles stay out of the store")

        // Framing on the other display: it starts from the styles just picked.
        first.toolbarModel.perform(.tool(.rect))
        second.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        second.mouseDragged(to: CGPoint(x: 150, y: 80))
        second.mouseUp(at: CGPoint(x: 150, y: 80))
        XCTAssertEqual(second.editor.toolStyles[.rect].color, .purple)
        second.adoptStoredStyles()
        XCTAssertEqual(second.editor.toolStyles[.rect].color, .purple, "Nothing new to take")
    }

    func testTheToolbarShowsEachToolsOptions() {
        func size(_ state: ScreenshotEditorToolbarModel.State) -> CGSize {
            NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }).fittingSize
        }
        func optionsWidth(_ state: ScreenshotEditorToolbarModel.State) -> CGFloat {
            NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar).fittingSize.width
        }
        var state = ScreenshotEditorToolbarModel.State()
        state.showsOptions = true
        state.showsColor = true
        var widths: [ScreenshotAnnotationTool: CGFloat] = [:]
        for tool in ScreenshotAnnotationTool.allCases where tool != .mosaic {
            state.optionsTool = tool
            state.tool = tool
            widths[tool] = optionsWidth(state)
        }
        XCTAssertGreaterThan(widths[.rect] ?? 0, widths[.ellipse] ?? 0, "Corners are for rectangles")
        XCTAssertGreaterThan(widths[.ellipse] ?? 0, widths[.line] ?? 0, "Lines have no fill")
        let rows = size(state).height
        state.showsColorPanel = true
        state.recentColors = [.teal, .pink]
        XCTAssertGreaterThan(size(state).height, rows + 30)
        for fill in ScreenshotAnnotationStyle.Fill.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: fill).isEmpty)
        }
        for dash in ScreenshotAnnotationStyle.Dash.allCases {
            XCTAssertFalse(ScreenshotEditorToolbarModel.symbol(for: dash).isEmpty)
        }
        XCTAssertTrue(ScreenshotEditorToolbarModel.help(for: .black).hasSuffix("0"))
        XCTAssertEqual(ScreenshotEditorToolbarModel.help(for: .init(hex: 0x010203)), "#010203")
        XCTAssertNotEqual(ScreenshotEditorToolbarModel.sizeCaption(for: .text),
                          ScreenshotEditorToolbarModel.sizeCaption(for: .pen))
        XCTAssertNotEqual(ScreenshotEditorToolbarModel.sizeCaption(for: .counter),
                          ScreenshotEditorToolbarModel.sizeCaption(for: .text))
    }

    // MARK: Long image

    func testTheLongImageEditorPicksColorsAndSharesTheStore() {
        let store = ScreenshotToolStyleStore()
        let canvas = ScreenshotLongImageCanvas(image: Self.twoColorImage(width: 200, height: 400), scale: 1,
                                               toolStyles: store)
        canvas.perform(.tool(.highlighter))
        XCTAssertTrue(canvas.toolbarState.showsColor)
        canvas.perform(.toggleColorPanel)
        XCTAssertTrue(canvas.toolbarState.showsColorPanel)
        canvas.perform(.pickColor)
        XCTAssertTrue(canvas.isPickingColor)
        canvas.mouseDown(at: CGPoint(x: 20, y: 300), clickCount: 1)
        canvas.mouseUp(at: CGPoint(x: 20, y: 300))
        XCTAssertFalse(canvas.isPickingColor)
        XCTAssertEqual(store.styles[.highlighter].color, ScreenshotAnnotationStyle.Color(hex: 0xFF0000))
        XCTAssertTrue(canvas.editor.document.isEmpty)

        canvas.perform(.pickColor)
        XCTAssertTrue(canvas.handleKeyDown(Key.escape, modifiers: []))
        XCTAssertFalse(canvas.isPickingColor)
        XCTAssertTrue(canvas.handleKeyDown(ScreenshotAnnotationEditor.colorKeyCodes[6], modifiers: []))
        XCTAssertEqual(store.styles[.highlighter].color, .purple)
        canvas.perform(.toggleColorPanel)
        canvas.perform(.color(.white))
        XCTAssertFalse(canvas.showsColorPanel)
        canvas.releaseImage()
    }
}
