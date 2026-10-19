import CoreGraphics
@testable import Typeflux
import XCTest

private actor CountingScrollRegistration: ScrollFrameRegistering {
    nonisolated var canSkipWhenLocallyAligned: Bool { true }
    private var calls = 0

    func verticalShifts(from previous: CGImage, to current: CGImage) async throws -> [Int] {
        calls += 1
        return []
    }

    func callCount() -> Int { calls }
}

final class DirectionalScrollStitcherTests: XCTestCase {
    private typealias Fixtures = ScrollCaptureFixtures

    private func frame(_ page: Fixtures.Page, _ offset: Int, axis: ScrollCaptureAxis) -> ScrollFrame {
        let image = page.frameImage(offset: offset, scrollingHeight: 200)
        return ScrollFrame(image: axis == .horizontal ? Fixtures.transpose(image) : image)!
    }

    func testBothAxesPreserveEveryPixelAndKeepPinnedBarsOnce() throws {
        for axis: ScrollCaptureAxis in [.vertical, .horizontal] {
            let page = Fixtures.page(header: 30, footer: 20)
            var stitcher = DirectionalScrollStitcher()
            XCTAssertTrue(stitcher.isEmpty)
            XCTAssertNil(stitcher.makeImage())
            XCTAssertEqual(stitcher.add(frame(page, 0, axis: axis)), .started)
            XCTAssertNil(stitcher.axis)
            XCTAssertEqual(stitcher.add(frame(page, 100, axis: axis)), .appended(rows: 100, suspicious: false))
            XCTAssertEqual(stitcher.axis, axis)
            XCTAssertEqual(stitcher.add(frame(page, 200, axis: axis)), .appended(rows: 100, suspicious: false))
            XCTAssertEqual(stitcher.headerHeight, 30)
            XCTAssertEqual(stitcher.footerHeight, 20)
            let expected = try XCTUnwrap(Fixtures.Pixels(width: page.width, height: 450,
                                                         bytes: page.expected(lastOffset: 200, scrollingHeight: 200))
                    .makeImage(space: Fixtures.space))
            let image = try XCTUnwrap(stitcher.makeImage())
            XCTAssertEqual(Fixtures.bytes(of: image),
                           Fixtures.bytes(of: axis == .horizontal ? Fixtures.transpose(expected) : expected))
            XCTAssertEqual(image.width, stitcher.width)
            XCTAssertEqual(image.height, stitcher.height)
            XCTAssertEqual(stitcher.segments.count, 3)
            XCTAssertNotNil(stitcher.footer)
        }
    }

    func testIdleAndTinyMovementDoNotChooseAnAxis() {
        let page = Fixtures.page()
        var stitcher = DirectionalScrollStitcher()
        XCTAssertFalse(stitcher.removeLastSegment())
        _ = stitcher.add(frame(page, 0, axis: .horizontal))
        XCTAssertEqual(stitcher.add(frame(page, 0, axis: .horizontal)), .unchanged)
        _ = stitcher.add(frame(page, 1, axis: .horizontal))
        XCTAssertNil(stitcher.axis)
        XCTAssertEqual(stitcher.segments.count, 1)
        _ = stitcher.add(frame(page, 80, axis: .horizontal))
        XCTAssertEqual(stitcher.axis, .horizontal)
        XCTAssertEqual(stitcher.width, 280)
    }

    func testReverseScrollingAndUndoKeepTheFurthestReferenceOnBothAxes() throws {
        for axis: ScrollCaptureAxis in [.vertical, .horizontal] {
            let page = Fixtures.page()
            var stitcher = DirectionalScrollStitcher()
            _ = stitcher.add(frame(page, 0, axis: axis))
            _ = stitcher.add(frame(page, 100, axis: axis))
            XCTAssertEqual(stitcher.add(frame(page, 98, axis: axis)), .scrolledBack)
            XCTAssertEqual(stitcher.add(frame(page, 100, axis: axis)), .unchanged)
            XCTAssertEqual(stitcher.segments.count, 2)
            _ = stitcher.add(frame(page, 180, axis: axis))
            XCTAssertTrue(stitcher.removeLastSegment())
            XCTAssertEqual(stitcher.segments.count, 2)
            XCTAssertEqual(stitcher.add(frame(page, 140, axis: axis)), .appended(rows: 40, suspicious: false))
            let image = try XCTUnwrap(stitcher.makeImage())
            XCTAssertEqual(axis == .vertical ? image.height : image.width, 340)
            XCTAssertEqual(stitcher.axis, axis)
        }
    }

    func testHorizontalLimitTrimsTheNewestColumns() throws {
        let page = Fixtures.page()
        var stitcher = DirectionalScrollStitcher(maxPixels: page.width * 350)
        _ = stitcher.add(frame(page, 0, axis: .horizontal))
        _ = stitcher.add(frame(page, 100, axis: .horizontal))
        XCTAssertEqual(stitcher.add(frame(page, 200, axis: .horizontal)), .reachedLimit(rows: 50))
        XCTAssertTrue(stitcher.isFull)
        XCTAssertEqual(try XCTUnwrap(stitcher.makeImage()).width, 350)
        XCTAssertTrue(stitcher.removeLastSegment())
        XCTAssertFalse(stitcher.isFull)
        XCTAssertEqual(stitcher.width, 300)
    }

    func testWrongFrameSizeIsRejectedAndAutomaticDefaultsToVertical() throws {
        let page = Fixtures.page()
        var stitcher = DirectionalScrollStitcher()
        _ = stitcher.add(frame(page, 0, axis: .vertical))
        stitcher.lockAxisForAutomatic()
        XCTAssertEqual(stitcher.axis, .vertical)
        let wrong = try XCTUnwrap(ScrollFrame(image: Fixtures.noise(width: 40, height: 80, seed: 1)))
        XCTAssertEqual(stitcher.add(wrong), .unaligned)
        XCTAssertEqual(stitcher.segments.count, 1)
        _ = stitcher.add(frame(page, 120, axis: .vertical), expectedShift: 120)
        XCTAssertEqual(stitcher.height, 320)
    }

    func testAlignedFramesUpdateWithoutNativeRegistrationAndDoubtfulFramesRetry() async throws {
        let page = Fixtures.page()
        let registration = CountingScrollRegistration()
        var stitcher = DirectionalScrollStitcher()
        _ = try await stitcher.addPreparingOffsets(page.frame(offset: 0, scrollingHeight: 200),
                                                    registration: registration)
        let outcome = try await stitcher.addPreparingOffsets(page.frame(offset: 100, scrollingHeight: 200),
                                                              registration: registration)
        XCTAssertEqual(outcome, .appended(rows: 100, suspicious: false))
        let fastCalls = await registration.callCount()
        XCTAssertEqual(fastCalls, 0)
        let noise = try XCTUnwrap(ScrollFrame(image: Fixtures.noise(width: page.width, height: 200, seed: 99)))
        _ = try await stitcher.addPreparingOffsets(noise, registration: registration)
        let retryCalls = await registration.callCount()
        XCTAssertEqual(retryCalls, 1)
    }

    func testTransposeKeepsColorAndOrientationAndIsReversible() throws {
        let image = try XCTUnwrap(Fixtures.Pixels(width: 2, height: 3, bytes: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
            255, 0, 255, 255, 0, 255, 255, 255
        ]).makeImage(space: Fixtures.space))
        let horizontal = try XCTUnwrap(ScrollCaptureAxis.horizontal.orient(image))
        XCTAssertEqual(Fixtures.bytes(of: horizontal), Fixtures.bytes(of: Fixtures.transpose(image)))
        XCTAssertEqual(try Fixtures.bytes(of: XCTUnwrap(ScrollCaptureAxis.horizontal.orient(horizontal))),
                       Fixtures.bytes(of: image))
        XCTAssertTrue(ScrollCaptureAxis.vertical.orient(image) === image)
    }
}
