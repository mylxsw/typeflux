import CoreGraphics
@testable import Typeflux
import XCTest

final class ScreenshotSelectionTests: XCTestCase {
    /// A 1512 × 982 pt display at 2×, to the right of a primary display.
    private let displayFrame = CGRect(x: 1920, y: 0, width: 1512, height: 982)

    private func window(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0,
                        bundle: String? = "app.test") -> ScreenSnapshot.Window {
        ScreenSnapshot.Window(id: id, frame: frame, processID: 1, bundleIdentifier: bundle,
                              applicationName: "App", title: nil, layer: layer)
    }

    private func selection(windows: [ScreenSnapshot.Window] = [], scale: CGFloat = 2) -> ScreenshotSelection {
        ScreenshotSelection(displayFrame: displayFrame, scale: scale, windows: windows)
    }

    // MARK: Windows

    func testWindowsBecomeLocalClippedAndFiltered() {
        let sut = selection(windows: [
            window(1, CGRect(x: 2020, y: 100, width: 400, height: 300)),
            // Partly off the right edge: clipped.
            window(2, CGRect(x: 3300, y: 50, width: 400, height: 100)),
            // On the other display: dropped.
            window(3, CGRect(x: 10, y: 10, width: 300, height: 300)),
            // The menu bar and the Dock are not snapped to.
            window(4, CGRect(x: 1920, y: 0, width: 1512, height: 24), layer: 24),
            window(5, CGRect(x: 1920, y: 0, width: 1512, height: 982), bundle: "com.apple.dock"),
            // Below normal windows (the desktop).
            window(6, CGRect(x: 1920, y: 0, width: 1512, height: 982), layer: -2147483624)
        ])

        XCTAssertEqual(sut.bounds, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(sut.windows, [CGRect(x: 100, y: 100, width: 400, height: 300),
                                     CGRect(x: 1380, y: 50, width: 132, height: 100)])
    }

    func testUntitledWindowsCoveringTheDisplayAreSkipped() {
        let overlay = ScreenSnapshot.Window(id: 9, frame: CGRect(x: 1900, y: -50, width: 1600, height: 1100),
                                            processID: 2, bundleIdentifier: "com.example.cursor",
                                            applicationName: "Cursor", title: nil, layer: 0)
        var titled = overlay
        titled.title = "Full screen document"
        let sut = selection(windows: [overlay, window(1, CGRect(x: 2020, y: 100, width: 200, height: 200)), titled])

        XCTAssertEqual(sut.windows, [CGRect(x: 100, y: 100, width: 200, height: 200), sut.bounds])
        XCTAssertTrue(ScreenshotSelection.isInvisibleOverlay(overlay, on: displayFrame))
        XCTAssertFalse(ScreenshotSelection.isInvisibleOverlay(titled, on: displayFrame))
    }

    func testWindowAtPointPrefersTheFrontMostWindow() {
        let sut = selection(windows: [
            window(1, CGRect(x: 2020, y: 100, width: 200, height: 200)),
            window(2, CGRect(x: 1950, y: 50, width: 600, height: 600))
        ])

        XCTAssertEqual(sut.window(at: CGPoint(x: 150, y: 150)), CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertNil(sut.window(at: CGPoint(x: 40, y: 40)), "Above the larger window")
        XCTAssertEqual(sut.window(at: CGPoint(x: 600, y: 600)), CGRect(x: 30, y: 50, width: 600, height: 600))
        XCTAssertNil(sut.window(at: CGPoint(x: 1000, y: 900)))
    }

    func testHoverHighlightsTheWindowUntilSomethingIsSelected() {
        var sut = selection(windows: [window(1, CGRect(x: 2020, y: 100, width: 200, height: 200))])

        sut.pointerMoved(to: CGPoint(x: 150, y: 150))
        XCTAssertEqual(sut.hovered, CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(sut.highlighted, sut.hovered)
        XCTAssertEqual(sut.sizeLabel, "200 × 200 pt · 400 × 400 px")

        sut.pointerExited()
        XCTAssertNil(sut.pointer)
        XCTAssertNil(sut.hovered)

        _ = sut.selectAll()
        sut.pointerMoved(to: CGPoint(x: 150, y: 150))
        XCTAssertNil(sut.hovered)
        XCTAssertEqual(sut.highlighted, sut.bounds)
    }

    // MARK: Dragging

    func testDragCreatesARegionOnWholePoints() {
        var sut = selection()

        XCTAssertEqual(sut.mouseDown(at: CGPoint(x: 100.4, y: 200.6)), .none)
        XCTAssertTrue(sut.isDragging)
        XCTAssertEqual(sut.mouseDragged(to: CGPoint(x: 101, y: 201)), .changed)
        XCTAssertNil(sut.rect, "Below the click tolerance nothing is drawn yet")

        XCTAssertEqual(sut.mouseDragged(to: CGPoint(x: 400.2, y: 500.7)), .changed)
        XCTAssertEqual(sut.rect, CGRect(x: 100, y: 201, width: 300, height: 300))
        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 400.2, y: 500.7)), .committed)
        XCTAssertFalse(sut.isDragging)
        XCTAssertEqual(sut.pixelSize, ScreenPixelSize(width: 600, height: 600))
        XCTAssertEqual(sut.sizeLabel, "300 × 300 pt · 600 × 600 px")
    }

    func testDraggingUpAndLeftNormalizesTheRegion() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 400, y: 400))
        _ = sut.mouseDragged(to: CGPoint(x: 100, y: 150))

        XCTAssertEqual(sut.rect, CGRect(x: 100, y: 150, width: 300, height: 250))
    }

    func testDragIsClampedToTheDisplay() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 1400, y: 900))
        _ = sut.mouseDragged(to: CGPoint(x: 2400, y: 1500))

        XCTAssertEqual(sut.rect, CGRect(x: 1400, y: 900, width: 112, height: 82))
        XCTAssertEqual(sut.pointer, CGPoint(x: 1512, y: 982))
    }

    func testClickPicksTheWindowUnderThePointer() {
        var sut = selection(windows: [window(1, CGRect(x: 2020, y: 100, width: 200, height: 200))])
        _ = sut.mouseDown(at: CGPoint(x: 150, y: 150))
        _ = sut.mouseDragged(to: CGPoint(x: 151, y: 151))

        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 151, y: 151)), .committed)
        XCTAssertEqual(sut.rect, CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    func testClickBetweenWindowsPicksTheWholeDisplay() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 700, y: 700))

        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 700, y: 700)), .committed)
        XCTAssertEqual(sut.rect, sut.bounds)
    }

    func testSpaceMovesTheRegionWhileDrawingIt() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 100, y: 100))
        _ = sut.mouseDragged(to: CGPoint(x: 300, y: 200))
        XCTAssertEqual(sut.rect, CGRect(x: 100, y: 100, width: 200, height: 100))

        _ = sut.mouseDragged(to: CGPoint(x: 350, y: 260), movesSelection: true)
        XCTAssertEqual(sut.rect, CGRect(x: 150, y: 160, width: 200, height: 100))

        // Space released: the far corner follows the pointer again from the moved anchor.
        _ = sut.mouseDragged(to: CGPoint(x: 450, y: 360))
        XCTAssertEqual(sut.rect, CGRect(x: 150, y: 160, width: 300, height: 200))
    }

    func testSpaceMoveKeepsAReversedDragReversed() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 300, y: 300))
        _ = sut.mouseDragged(to: CGPoint(x: 100, y: 200))
        _ = sut.mouseDragged(to: CGPoint(x: 0, y: 0), movesSelection: true)

        // Moved as far as the display allows, the anchor still being the bottom-right corner.
        XCTAssertEqual(sut.rect, CGRect(x: 0, y: 0, width: 200, height: 100))
        _ = sut.mouseDragged(to: CGPoint(x: 50, y: 20))
        XCTAssertEqual(sut.rect, CGRect(x: 50, y: 20, width: 150, height: 80))
    }

    func testDraggingInsideMovesTheRegionWithinTheDisplay() {
        var sut = selection()
        _ = sut.select(CGRect(x: 100, y: 100, width: 200, height: 100))

        XCTAssertEqual(sut.hit(at: CGPoint(x: 200, y: 150)), .inside)
        _ = sut.mouseDown(at: CGPoint(x: 200, y: 150))
        XCTAssertEqual(sut.mouseDragged(to: CGPoint(x: 250, y: 170)), .changed)
        XCTAssertEqual(sut.rect, CGRect(x: 150, y: 120, width: 200, height: 100))

        _ = sut.mouseDragged(to: CGPoint(x: -500, y: -500))
        XCTAssertEqual(sut.rect, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(sut.mouseUp(at: .zero), .changed)
    }

    func testPressingOutsideTheRegionStartsANewOne() {
        var sut = selection()
        _ = sut.select(CGRect(x: 100, y: 100, width: 200, height: 100))
        _ = sut.mouseDown(at: CGPoint(x: 800, y: 800))
        _ = sut.mouseDragged(to: CGPoint(x: 900, y: 900))

        XCTAssertEqual(sut.rect, CGRect(x: 800, y: 800, width: 100, height: 100))
        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 900, y: 900)), .committed)
    }

    func testHandlesResizeAndFlipAcrossTheOppositeEdge() {
        var sut = selection()
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        _ = sut.select(rect)

        XCTAssertEqual(sut.hit(at: CGPoint(x: 302, y: 199)), .handle(.bottomRight))
        _ = sut.mouseDown(at: CGPoint(x: 300, y: 200))
        _ = sut.mouseDragged(to: CGPoint(x: 360, y: 260))
        XCTAssertEqual(sut.rect, CGRect(x: 100, y: 100, width: 260, height: 160))

        _ = sut.mouseDragged(to: CGPoint(x: 50, y: 40))
        XCTAssertEqual(sut.rect, CGRect(x: 50, y: 40, width: 50, height: 60))
        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 50, y: 40)), .changed)
    }

    func testEveryHandleMovesItsOwnEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let point = CGPoint(x: 50, y: 400)
        let expected: [ScreenshotSelection.Handle: CGRect] = [
            .topLeft: CGRect(x: 50, y: 200, width: 250, height: 200),
            .top: CGRect(x: 100, y: 200, width: 200, height: 200),
            .topRight: CGRect(x: 50, y: 200, width: 50, height: 200),
            .right: CGRect(x: 50, y: 100, width: 50, height: 100),
            .bottomRight: CGRect(x: 50, y: 100, width: 50, height: 300),
            .bottom: CGRect(x: 100, y: 100, width: 200, height: 300),
            .bottomLeft: CGRect(x: 50, y: 100, width: 250, height: 300),
            .left: CGRect(x: 50, y: 100, width: 250, height: 100)
        ]
        for handle in ScreenshotSelection.Handle.allCases {
            XCTAssertEqual(ScreenshotSelection.resized(rect, handle: handle, to: point, within: bounds),
                           expected[handle], "\(handle)")
            let anchor = ScreenshotSelection.point(for: handle, in: rect)
            var sut = ScreenshotSelection(displayFrame: bounds, scale: 1, windows: [])
            _ = sut.select(rect)
            XCTAssertEqual(sut.hit(at: anchor), .handle(handle))
        }
    }

    func testResizeNeverCollapsesBelowOnePoint() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        let collapsed = ScreenshotSelection.resized(rect, handle: .right, to: CGPoint(x: 100, y: 150), within: bounds)
        XCTAssertEqual(collapsed, CGRect(x: 100, y: 100, width: 1, height: 100))

        let atCorner = ScreenshotSelection.resized(CGRect(x: 999, y: 999, width: 1, height: 1), handle: .topLeft,
                                                   to: CGPoint(x: 1000, y: 1000), within: bounds)
        XCTAssertEqual(atCorner, CGRect(x: 999, y: 999, width: 1, height: 1))
    }

    func testDoubleClickInsideConfirms() {
        var sut = selection()
        _ = sut.select(CGRect(x: 100, y: 100, width: 200, height: 100))

        XCTAssertEqual(sut.mouseDown(at: CGPoint(x: 150, y: 150), clickCount: 2), .confirmed)
        XCTAssertFalse(sut.isDragging)
        // Outside the region a double click just starts a new one.
        XCTAssertEqual(sut.mouseDown(at: CGPoint(x: 900, y: 900), clickCount: 2), .none)
    }

    func testDragAndReleaseWithoutPressDoNothing() {
        var sut = selection()

        XCTAssertEqual(sut.mouseDragged(to: CGPoint(x: 10, y: 10)), .none)
        XCTAssertEqual(sut.mouseUp(at: CGPoint(x: 10, y: 10)), .none)
        XCTAssertNil(sut.rect)
    }

    // MARK: Keys

    func testSelectAllTakesTheDisplay() {
        var sut = selection()
        _ = sut.mouseDown(at: CGPoint(x: 10, y: 10))

        XCTAssertEqual(sut.selectAll(), .committed)
        XCTAssertFalse(sut.isDragging)
        XCTAssertEqual(sut.rect, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(sut.pixelSize, ScreenPixelSize(width: 3024, height: 1964))
    }

    func testNudgeMovesByStepsAndStopsAtTheEdge() {
        var sut = selection()
        XCTAssertEqual(sut.nudge(by: CGSize(width: 1, height: 0)), .none, "Nothing to move yet")

        _ = sut.select(CGRect(x: 1, y: 100, width: 200, height: 100))
        XCTAssertEqual(sut.nudge(by: CGSize(width: ScreenshotSelection.largeNudgeStep, height: -1)), .changed)
        XCTAssertEqual(sut.rect, CGRect(x: 11, y: 99, width: 200, height: 100))

        XCTAssertEqual(sut.nudge(by: CGSize(width: -20, height: 0)), .changed)
        XCTAssertEqual(sut.rect?.minX, 0)
        XCTAssertEqual(sut.nudge(by: CGSize(width: -1, height: 0)), .none, "Already at the edge")
    }

    func testNudgeIsIgnoredWhileDragging() {
        var sut = selection()
        _ = sut.select(CGRect(x: 100, y: 100, width: 200, height: 100))
        _ = sut.mouseDown(at: CGPoint(x: 150, y: 150))

        XCTAssertEqual(sut.nudge(by: CGSize(width: 1, height: 0)), .none)
    }

    func testClearDropsTheRegionAndHoversAgain() {
        var sut = selection(windows: [window(1, CGRect(x: 2020, y: 100, width: 200, height: 200))])
        sut.pointerMoved(to: CGPoint(x: 150, y: 150))
        _ = sut.selectAll()

        sut.clear()
        XCTAssertNil(sut.rect)
        XCTAssertEqual(sut.hovered, CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    // MARK: Labels

    func testSizeLabelOnAOneTimesDisplayShowsPointsOnly() {
        var sut = selection(scale: 1)
        XCTAssertNil(sut.sizeLabel)
        XCTAssertNil(sut.pixelSize)

        _ = sut.select(CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertEqual(sut.sizeLabel, "64 × 48")
        XCTAssertEqual(sut.pixelSize, ScreenPixelSize(width: 64, height: 48))
    }

    func testFractionalScaleRoundsPixels() {
        var sut = selection(scale: 1.5)
        _ = sut.select(CGRect(x: 0, y: 0, width: 101, height: 33))

        XCTAssertEqual(sut.pixelSize, ScreenPixelSize(width: 152, height: 50))
        XCTAssertEqual(sut.sizeLabel, "101 × 33 pt · 152 × 50 px")
    }

    func testScaleBelowOneIsTreatedAsOne() {
        XCTAssertEqual(selection(scale: 0).scale, 1)
    }

    func testRectHelpers() {
        XCTAssertTrue(ScreenshotSelection.isClick(from: .zero, to: CGPoint(x: 2, y: -2)))
        XCTAssertFalse(ScreenshotSelection.isClick(from: .zero, to: CGPoint(x: 3, y: 0)))
        XCTAssertEqual(ScreenshotSelection.snapped(CGRect(x: 0.4, y: 0.6, width: 10.2, height: 9.8)),
                       CGRect(x: 0, y: 1, width: 11, height: 9))
        XCTAssertEqual(ScreenshotSelection.clamp(CGPoint(x: -5, y: 50), to: CGRect(x: 0, y: 0, width: 10, height: 10)),
                       CGPoint(x: 0, y: 10))
    }
}

private extension ScreenshotSelection {
    /// Selects a region as the tests need it, through the public inputs.
    mutating func select(_ rect: CGRect) -> Outcome {
        _ = mouseDown(at: rect.origin)
        _ = mouseDragged(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return mouseUp(at: CGPoint(x: rect.maxX, y: rect.maxY))
    }
}
