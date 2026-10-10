import AppKit
import CoreVideo
@testable import Typeflux
import XCTest

/// The scrolling capture's panels, bar and preview, and its driver, monitor and stream settings.
@MainActor
final class ScrollCaptureUITests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key
    private let display = CGRect(x: 0, y: 0, width: 800, height: 600)

    private final class Calls {
        var pauses = 0, undos = 0, cancels = 0, finishes = 0, allows = 0
    }

    private func actions(_ calls: Calls) -> ScrollCaptureActions {
        ScrollCaptureActions(togglePause: { calls.pauses += 1 }, undo: { calls.undos += 1 },
                             cancel: { calls.cancels += 1 }, finish: { calls.finishes += 1 },
                             openAccessibilitySettings: { calls.allows += 1 })
    }

    // MARK: Layout

    func testDimPanelsSurroundTheRegionAndLeaveItOpen() {
        let region = CGRect(x: 100, y: 50, width: 300, height: 200)

        let rects = ScrollCaptureLayout.dimRects(around: region, in: display)

        XCTAssertEqual(rects, [CGRect(x: 0, y: 0, width: 800, height: 50),
                               CGRect(x: 0, y: 250, width: 800, height: 350),
                               CGRect(x: 0, y: 50, width: 100, height: 200),
                               CGRect(x: 400, y: 50, width: 400, height: 200)])
        XCTAssertFalse(rects.contains { $0.intersects(region) })
        let covered = rects.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(covered, display.width * display.height - region.width * region.height)
        // A region touching the edges needs fewer panels; one off the display dims all of it.
        XCTAssertEqual(ScrollCaptureLayout.dimRects(around: CGRect(x: 0, y: 0, width: 800, height: 300), in: display),
                       [CGRect(x: 0, y: 300, width: 800, height: 300)])
        XCTAssertEqual(ScrollCaptureLayout.dimRects(around: CGRect(x: 900, y: 0, width: 10, height: 10), in: display),
                       [display])
        XCTAssertEqual(ScrollCaptureLayout.outlineRect(around: region), region.insetBy(dx: -2, dy: -2))
    }

    func testTheBarGoesBelowAboveOrInside() {
        let size = CGSize(width: 300, height: 40)

        let below = ScrollCaptureLayout.barFrame(size: size, region: CGRect(x: 100, y: 50, width: 300, height: 200),
                                                 display: display)
        XCTAssertEqual(below, CGRect(x: 100, y: 260, width: 300, height: 40))
        let above = ScrollCaptureLayout.barFrame(size: size, region: CGRect(x: 100, y: 200, width: 300, height: 380),
                                                 display: display)
        XCTAssertEqual(above.maxY, 190)
        let inside = ScrollCaptureLayout.barFrame(size: size, region: display, display: display)
        XCTAssertEqual(inside.maxY, 592)
        let clamped = ScrollCaptureLayout.barFrame(size: size, region: CGRect(x: 700, y: 50, width: 100, height: 100),
                                                   display: display)
        XCTAssertEqual(clamped.maxX, 792, "Kept on the display")
    }

    func testThePreviewGoesRightLeftOrInside() {
        let right = ScrollCaptureLayout.previewFrame(region: CGRect(x: 100, y: 50, width: 300, height: 100),
                                                     display: display)
        XCTAssertEqual(right, CGRect(x: 410, y: 50, width: 132, height: 160), "At least 160 tall")
        let left = ScrollCaptureLayout.previewFrame(region: CGRect(x: 500, y: 50, width: 290, height: 300),
                                                    display: display)
        XCTAssertEqual(left.maxX, 490)
        let inside = ScrollCaptureLayout.previewFrame(region: display, display: display)
        XCTAssertEqual(inside, CGRect(x: 660, y: 8, width: 132, height: 584))
    }

    // MARK: Preview

    private func preview(segmentHeights: [Int], suspicious: Set<Int> = [], header: Int = 0,
                         footer: Int? = nil) -> ScrollCapturePreview {
        ScrollCapturePreview(
            segments: segmentHeights.enumerated().map { index, height in
                ScrollStitcher.Segment(image: ScreenCaptureTestSupport.image(width: 100, height: height),
                                       isSuspicious: suspicious.contains(index))
            },
            footer: footer.map { ScreenCaptureTestSupport.image(width: 100, height: $0) },
            headerHeight: header, width: 100
        )
    }

    func testThePreviewIsScaledToItsWidthAndShowsTheNewestRows() {
        let bounds = CGRect(x: 0, y: 0, width: 66, height: 116)
        // 50 points wide inside the insets: half size.
        let short = ScrollCapturePreviewView.layout(preview(segmentHeights: [100, 40], header: 20, footer: 10),
                                                       in: bounds)
        XCTAssertEqual(short.segments.map(\.frame), [CGRect(x: 8, y: 8, width: 50, height: 50),
                                                     CGRect(x: 8, y: 58, width: 50, height: 20)])
        XCTAssertEqual(short.segments.map(\.isNewest), [false, true])
        XCTAssertEqual(short.header, CGRect(x: 8, y: 8, width: 50, height: 10))
        XCTAssertEqual(short.footer, CGRect(x: 8, y: 78, width: 50, height: 5))

        let tall = ScrollCapturePreviewView.layout(preview(segmentHeights: [100, 100, 100], suspicious: [1]),
                                                      in: bounds)
        XCTAssertEqual(tall.segments.last?.frame.maxY, 108, "Pinned to the newest rows")
        XCTAssertEqual(tall.segments.map(\.isSuspicious), [false, true, false])
        XCTAssertNil(tall.header)
        XCTAssertNil(tall.footer)

        let single = ScrollCapturePreviewView.layout(preview(segmentHeights: [100]), in: bounds)
        XCTAssertEqual(single.segments.map(\.isNewest), [false], "The first frame is not outlined as new")
        XCTAssertTrue(ScrollCapturePreviewView.layout(ScrollCapturePreview(), in: bounds).segments.isEmpty)
    }

    func testThePreviewDraws() throws {
        let view = ScrollCapturePreviewView(frame: CGRect(x: 0, y: 0, width: 132, height: 200))
        view.preview = preview(segmentHeights: [200, 120, 120], suspicious: [1], header: 20, footer: 20)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)), "Clicks pass through")
        XCTAssertNotNil(bitmap.colorAt(x: 66, y: 100))
    }

    // MARK: Bar

    func testTheBarSaysWhatIsHappening() {
        var state = ScrollCaptureViewState()
        XCTAssertEqual(ScrollCaptureBar.message(for: state), L("screenshot.scroll.status.starting"))
        XCTAssertNil(ScrollCaptureBar.sizeText(for: state))
        let statuses: [(ScrollCaptureViewState.Status, String)] = [
            (.scrolling, "scrolling"), (.paused, "paused"), (.pausedByMouse, "pausedByMouse"),
            (.misaligned, "misaligned"), (.needsAccessibility, "needsAccessibility")
        ]
        for (status, key) in statuses {
            state.status = status
            XCTAssertEqual(ScrollCaptureBar.message(for: state), L("screenshot.scroll.status.\(key)"))
            XCTAssertNotEqual(L("screenshot.scroll.status.\(key)"), "screenshot.scroll.status.\(key)")
        }
        state.pixelSize = ScreenPixelSize(width: 1280, height: 5400)
        XCTAssertEqual(ScrollCaptureBar.sizeText(for: state), "1280 × 5400 px")
        state.lastSegmentSuspicious = true
        XCTAssertEqual(ScrollCaptureBar.message(for: state), L("screenshot.scroll.status.suspicious"))
    }

    func testTheBarsKeysActOnlyWhenTheyCan() {
        let calls = Calls()
        let bar = ScrollCaptureBarView(frame: .zero)
        XCTAssertFalse(bar.handleKey(Key.escape), "No actions yet")
        XCTAssertEqual(bar.show(ScrollCaptureViewState()), .zero)
        bar.actions = actions(calls)

        // Before the first frame only esc does something.
        _ = bar.show(ScrollCaptureViewState())
        for key in [Key.space, Key.delete, Key.returnKey, Key.escape] { XCTAssertTrue(bar.handleKey(key)) }
        XCTAssertEqual([calls.pauses, calls.undos, calls.finishes, calls.cancels], [0, 0, 0, 1])
        XCTAssertFalse(bar.handleKey(Key.keyA))

        var state = ScrollCaptureViewState(status: .scrolling, pixelSize: ScreenPixelSize(width: 10, height: 20),
                                           canUndo: true)
        let size = bar.show(state)
        XCTAssertGreaterThan(size.width, 200)
        XCTAssertEqual(bar.state, state)
        for key in [Key.space, Key.forwardDelete, Key.enter] { bar.handleKey(key) }
        XCTAssertEqual([calls.pauses, calls.undos, calls.finishes], [1, 1, 1])

        state.status = .needsAccessibility
        _ = bar.show(state)
        bar.handleKey(Key.space)
        XCTAssertEqual(calls.pauses, 1)
        XCTAssertTrue(bar.acceptsFirstResponder)
    }

    // MARK: Panels

    func testTheOverlayLeavesTheRegionUncovered() throws {
        let controller = ScrollCaptureOverlayController(primaryDisplayHeight: { 600 })
        let calls = Calls()
        let region = ScrollCaptureRegion(displayID: 1, displayFrame: display, scale: 2,
                                         rect: CGRect(x: 100, y: 50, width: 300, height: 200))
        controller.update(ScrollCaptureViewState(), preview: ScrollCapturePreview())
        XCTAssertFalse(controller.isPresented)

        controller.present(region, actions: actions(calls))
        defer { controller.dismiss() }

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.dimPanels.count, 4)
        // AppKit frames: the region at y = 600 - 250 from the bottom.
        let regionInAppKit = CGRect(x: 100, y: 350, width: 300, height: 200)
        XCTAssertFalse(controller.dimPanels.contains { $0.frame.intersects(regionInAppKit) })
        let outline = try XCTUnwrap(controller.outlinePanel)
        XCTAssertTrue(outline.ignoresMouseEvents)
        XCTAssertEqual(outline.frame, regionInAppKit.insetBy(dx: -2, dy: -2))
        XCTAssertNil(outline.contentView?.hitTest(CGPoint(x: 5, y: 5)))
        XCTAssertTrue(try XCTUnwrap(controller.previewPanel).ignoresMouseEvents)
        let barPanel = try XCTUnwrap(controller.barPanel)
        XCTAssertTrue(barPanel.canBecomeKey)
        XCTAssertFalse(barPanel.canBecomeMain)
        XCTAssertFalse(controller.dimPanels[0].canBecomeKey)
        XCTAssertLessThan(barPanel.frame.maxY, regionInAppKit.minY, "Under the region")
        XCTAssertTrue(controller.dimPanels.allSatisfy { $0.level == .screenSaver && $0.isVisible })

        let state = ScrollCaptureViewState(status: .scrolling, pixelSize: ScreenPixelSize(width: 600, height: 900),
                                           canUndo: true)
        controller.update(state, preview: preview(segmentHeights: [400, 300]))
        XCTAssertEqual(controller.barView?.state, state)
        XCTAssertEqual(controller.previewView?.preview.segments.count, 2)
        controller.barView?.handleKey(Key.returnKey)
        XCTAssertEqual(calls.finishes, 1)

        let panels = controller.dimPanels + [outline, barPanel]
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
    }

    func testTheFillAndOutlineDraw() throws {
        for view in [ScrollCaptureFillView(frame: CGRect(x: 0, y: 0, width: 20, height: 20), color: .black),
                     ScrollCaptureOutlineView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
        }
    }

    // MARK: Driver

    func testTheDriverMovesThePointerInAndBackOut() {
        var pointer = CGPoint(x: 900, y: 900)
        var warps: [CGPoint] = []
        var posted: [CGEvent] = []
        let driver = ScrollDriver(isTrusted: { true }, pointerLocation: { pointer },
                                  warp: { warps.append($0); pointer = $0 }, post: { posted.append($0) })
        let region = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertTrue(driver.canScroll)

        driver.begin(in: region)
        XCTAssertEqual(warps, [CGPoint(x: 200, y: 150)])
        XCTAssertEqual(driver.anchor, CGPoint(x: 200, y: 150))
        driver.scroll(by: 60)
        let event = try? XCTUnwrap(posted.first)
        XCTAssertEqual(event?.location, CGPoint(x: 200, y: 150))
        XCTAssertEqual(event?.getIntegerValueField(.eventSourceUserData), ScrollDriverEventMark.userData)
        XCTAssertEqual(event?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -60)

        driver.end()
        XCTAssertEqual(warps.last, CGPoint(x: 900, y: 900), "Back where it was")
        XCTAssertNil(driver.anchor)
        driver.end()
        XCTAssertEqual(warps.count, 2)
    }

    func testTheDriverLeavesAPointerTheUserMoved() {
        var pointer = CGPoint(x: 150, y: 120)
        var warps: [CGPoint] = []
        let driver = ScrollDriver(isTrusted: { false }, pointerLocation: { pointer }, warp: { warps.append($0) },
                                  post: { _ in })
        XCTAssertFalse(driver.canScroll)

        driver.begin(in: CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertTrue(warps.isEmpty, "Already inside")
        XCTAssertEqual(driver.anchor, pointer)
        driver.end()
        XCTAssertTrue(warps.isEmpty)

        pointer = CGPoint(x: 10, y: 10)
        driver.begin(in: CGRect(x: 100, y: 100, width: 200, height: 100))
        pointer = CGPoint(x: 400, y: 400)
        driver.end()
        XCTAssertEqual(warps, [CGPoint(x: 200, y: 150)], "The user moved it: left alone")
    }

    func testWheelEvents() {
        let up = ScrollDriver.wheelEvent(points: -30.4, at: CGPoint(x: 1, y: 2))
        XCTAssertEqual(up?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 30)
        XCTAssertNil(ScrollDriver.wheelEvent(points: .infinity, at: .zero))
        var posted = 0
        let driver = ScrollDriver(isTrusted: { true }, pointerLocation: { .zero }, warp: { _ in },
                                  post: { _ in posted += 1 })
        driver.scroll(by: .nan)
        XCTAssertEqual(posted, 0)
    }

    // MARK: Monitor

    func testOnlyTheUsersOwnInputCounts() {
        let point = CGPoint(x: 3, y: 4)
        XCTAssertEqual(ScrollUserActivityMonitor.activity(type: .scrollWheel, userData: 0, location: point), .scrolled)
        XCTAssertNil(ScrollUserActivityMonitor.activity(type: .scrollWheel, userData: ScrollDriverEventMark.userData,
                                                        location: point))
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertEqual(ScrollUserActivityMonitor.activity(type: type, userData: 0, location: point), .clicked)
        }
        XCTAssertEqual(ScrollUserActivityMonitor.activity(type: .mouseMoved, userData: 0, location: point),
                       .moved(point))
        XCTAssertEqual(ScrollUserActivityMonitor.activity(type: .leftMouseDragged, userData: 0, location: point),
                       .moved(point))
        XCTAssertNil(ScrollUserActivityMonitor.activity(type: .keyDown, userData: 0, location: point))

        let monitor = ScrollUserActivityMonitor()
        monitor.start { _ in }
        monitor.start { _ in }
        monitor.stop()
        monitor.stop()
    }

    // MARK: Stream

    func testTheStreamCapturesTheRegionAtNativePixels() {
        let region = ScrollCaptureRegion(displayID: 3, displayFrame: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
                                         scale: 2, rect: CGRect(x: 1540, y: -100, width: 400.5, height: 300))
        XCTAssertEqual(region.localRect, CGRect(x: 100, y: 100, width: 400.5, height: 300))
        XCTAssertEqual(region.pixelSize, ScreenPixelSize(width: 801, height: 600))

        let config = ScreenCaptureStreamFrameSource.configuration(for: region)

        XCTAssertEqual(config.sourceRect, region.localRect)
        XCTAssertEqual(config.width, 801)
        XCTAssertEqual(config.height, 600)
        XCTAssertFalse(config.showsCursor)
        XCTAssertEqual(config.minimumFrameInterval.seconds, 1.0 / 15, accuracy: 0.0001)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        let source = ScreenCaptureStreamFrameSource(ownProcessID: 1)
        source.stop()
    }

    func testStreamPixelsAreCopiedOut() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 3, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0 ..< 3 {
            for column in 0 ..< 4 {
                // BGRA: pure blue.
                let offset = row * bytesPerRow + column * 4
                base[offset] = 255
                base[offset + 1] = 0
                base[offset + 2] = 0
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let image = try XCTUnwrap(ScreenCaptureStreamFrameSource.copyImage(of: pixels))
        // Overwriting the buffer afterwards does not change the copy.
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, bytesPerRow * 3)
        CVPixelBufferUnlockBaseAddress(pixels, [])

        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        let rgba = ScrollCaptureFixtures.bytes(of: image)
        XCTAssertLessThan(rgba[0], 10)
        XCTAssertGreaterThan(rgba[2], 240)
    }
}
