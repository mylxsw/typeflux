// swiftlint:disable file_length type_body_length
import CoreGraphics
@testable import Typeflux
import XCTest

final class ScrollStitcherTests: XCTestCase {
    private typealias Fixtures = ScrollCaptureFixtures
    private let scrolling = 250

    /// Proposes fixed shifts and records what it was shown.
    private final class Estimator: ScrollOffsetEstimating, @unchecked Sendable {
        var shifts: [Int]
        private(set) var sizes: [(Int, Int)] = []

        init(_ shifts: [Int]) { self.shifts = shifts }

        func verticalShifts(from previous: CGImage, to current: CGImage) -> [Int] {
            sizes.append((previous.height, current.height))
            return shifts
        }
    }

    private func stitch(_ page: Fixtures.Page, offsets: [Int], stitcher: inout ScrollStitcher)
        -> [ScrollStitcher.Outcome] {
        offsets.map { stitcher.add(page.frame(offset: $0, scrollingHeight: scrolling)) }
    }

    // MARK: Joining

    func testFramesJoinIntoTheExactPage() throws {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        let offsets = [0, 120, 240, 360, 480, 600]

        let outcomes = stitch(page, offsets: offsets, stitcher: &stitcher)

        XCTAssertEqual(outcomes.first, .started)
        XCTAssertEqual(Array(outcomes.dropFirst()), Array(repeating: .appended(rows: 120, suspicious: false), count: 5))
        XCTAssertEqual(stitcher.headerHeight, 0)
        XCTAssertEqual(stitcher.footerHeight, 0)
        XCTAssertNil(stitcher.footer)
        let image = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(image.width, page.width)
        XCTAssertEqual(image.height, 600 + scrolling)
        XCTAssertEqual(stitcher.height, image.height)
        XCTAssertEqual(stitcher.pixelCount, image.width * image.height)
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 600, scrollingHeight: scrolling))
        XCTAssertEqual(stitcher.segments.map(\.height), [250, 120, 120, 120, 120, 120])
        XCTAssertFalse(stitcher.segments.contains { $0.isSuspicious })
    }

    func testUnevenStepsJoinExactly() throws {
        let page = Fixtures.page(seed: 11)
        var stitcher = ScrollStitcher()
        let offsets = [0, 37, 150, 151, 300, 503]

        let outcomes = stitch(page, offsets: offsets, stitcher: &stitcher)

        XCTAssertEqual(outcomes, [.started, .appended(rows: 37, suspicious: false),
                                  .appended(rows: 113, suspicious: false), .appended(rows: 1, suspicious: false),
                                  .appended(rows: 149, suspicious: false), .appended(rows: 203, suspicious: false)])
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 503, scrollingHeight: scrolling))
    }

    func testPinnedHeaderAndBottomBarAppearOnce() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher()
        let offsets = [0, 120, 240, 360]

        let outcomes = stitch(page, offsets: offsets, stitcher: &stitcher)

        XCTAssertEqual(Array(outcomes.dropFirst()), Array(repeating: .appended(rows: 120, suspicious: false), count: 3))
        XCTAssertEqual(stitcher.headerHeight, 30)
        XCTAssertEqual(stitcher.footerHeight, 20)
        XCTAssertEqual(stitcher.footer?.height, 20)
        // The first frame keeps its header; its bottom bar moves to the end.
        XCTAssertEqual(stitcher.segments.first?.height, 30 + scrolling)
        let image = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(image.height, 30 + 360 + scrolling + 20)
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 360, scrollingHeight: scrolling))
    }

    /// The frame at `offset` with the 12 rows under the 30-row header blurred differently each time,
    /// as macOS 26 does with content scrolling under a pinned bar.
    private func blurredUnderHeader(_ page: Fixtures.Page, offset: Int) -> (frame: ScrollFrame, band: [UInt8]) {
        var bytes = Fixtures.bytes(of: page.frameImage(offset: offset, scrollingHeight: scrolling))
        var generator = Fixtures.Generator(state: UInt64(offset + 1))
        let rowBytes = page.width * 4
        for index in 30 * rowBytes ..< 42 * rowBytes where index % 4 != 3 {
            bytes[index] = UInt8(120 + generator.next() % 100)
        }
        let image = Fixtures.Pixels(width: page.width, height: 300, bytes: bytes).makeImage(space: Fixtures.space)!
        return (ScrollFrame(image: image)!, Array(bytes[30 * rowBytes ..< 42 * rowBytes]))
    }

    func testABlurredBandUnderThePinnedHeaderJoinsIt() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher()
        let first = blurredUnderHeader(page, offset: 0)
        XCTAssertEqual(stitcher.add(first.frame), .started)

        XCTAssertEqual(stitcher.add(blurredUnderHeader(page, offset: 120).frame), .appended(rows: 120, suspicious: false))
        XCTAssertEqual(stitcher.add(blurredUnderHeader(page, offset: 240).frame), .appended(rows: 120, suspicious: false))

        XCTAssertEqual(stitcher.headerHeight, 42)
        XCTAssertEqual(stitcher.footerHeight, 20)
        // The header, the first frame's band, then the page from under the band on, then the bottom bar.
        let rowBytes = page.width * 4
        let expected = page.header + first.band + Array(page.bytes[12 * rowBytes ..< (240 + scrolling) * rowBytes])
            + page.footer
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())), expected)
    }

    func testBandsOnlyWidenTheBarsWhenTheyHelp() {
        let page = Fixtures.page(header: 30, footer: 20)
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let second = page.frame(offset: 120, scrollingHeight: scrolling).signature

        XCTAssertNil(ScrollStitcher.widenedFixedRows((30, 20), shift: 120, previous: first, current: second),
                     "Everything lines up: no band")
        XCTAssertNil(ScrollStitcher.widenedFixedRows((30, 20), shift: 0, previous: first, current: second))
        XCTAssertNil(ScrollStitcher.widenedFixedRows((30, 20), shift: 400, previous: first, current: second))
    }

    /// An editor's sticky scroll: once the content scrolls, the top rows show whatever the current
    /// scope is, different in every frame.
    func testStickyLinesAtTheTopStillLetLaterFramesLineUp() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(page.frame(offset: 0, scrollingHeight: scrolling)), .started)
        XCTAssertEqual(stitcher.add(page.frame(offset: 120, scrollingHeight: scrolling)),
                       .appended(rows: 120, suspicious: false))
        XCTAssertEqual(stitcher.headerHeight, 30)

        for (index, offset) in [240, 360].enumerated() {
            var bytes = Fixtures.bytes(of: page.frameImage(offset: offset, scrollingHeight: scrolling))
            var generator = Fixtures.Generator(state: UInt64(index + 40))
            let rowBytes = page.width * 4
            // Two sticky lines with a little of the page showing between them.
            for byte in 30 * rowBytes ..< 90 * rowBytes where byte % 4 != 3 && !(60 * rowBytes ..< 66 * rowBytes ~= byte) {
                bytes[byte] = UInt8(generator.next() % 200)
            }
            let frame = Fixtures.Pixels(width: page.width, height: 300, bytes: bytes).makeImage(space: Fixtures.space)!
            XCTAssertEqual(stitcher.add(ScrollFrame(image: frame)!), .appended(rows: 120, suspicious: false))
        }

        XCTAssertEqual(stitcher.headerHeight, 30, "Only the first scroll sets the bars")
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 360, scrollingHeight: scrolling))
    }

    func testTheFirstFrameAloneIsTheWholeFrame() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher()
        XCTAssertNil(stitcher.makeImage())
        XCTAssertTrue(stitcher.isEmpty)

        XCTAssertEqual(stitcher.add(page.frame(offset: 0, scrollingHeight: scrolling)), .started)

        let image = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 0, scrollingHeight: scrolling))
        XCTAssertFalse(stitcher.removeLastSegment())
    }

    // MARK: Nothing new

    func testAnUnchangedFrameAddsNothing() {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0, 120], stitcher: &stitcher)

        XCTAssertEqual(stitcher.add(page.frame(offset: 120, scrollingHeight: scrolling)), .unchanged)
        XCTAssertEqual(stitcher.height, 120 + scrolling)
    }

    func testScrollingBackAddsNothingAndScrollingOnContinues() throws {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0, 120, 240], stitcher: &stitcher)

        XCTAssertEqual(stitcher.add(page.frame(offset: 160, scrollingHeight: scrolling)), .scrolledBack)
        XCTAssertEqual(stitcher.add(page.frame(offset: 300, scrollingHeight: scrolling)),
                       .appended(rows: 60, suspicious: false))
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 300, scrollingHeight: scrolling))
    }

    func testFramesThatLineUpWithNothingAreDropped() {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0], stitcher: &stitcher)

        let noise = Fixtures.noise(width: page.width, height: scrolling, seed: 3)
        XCTAssertEqual(stitcher.add(ScrollFrame(image: noise)!), .unaligned)
        // Scrolled too far: no rows in common.
        XCTAssertEqual(stitcher.add(page.frame(offset: 600, scrollingHeight: scrolling)), .unaligned)
        let other = Fixtures.page(width: 80)
        XCTAssertEqual(stitcher.add(other.frame(offset: 0, scrollingHeight: scrolling)), .unaligned,
                       "A frame of another size")
        XCTAssertEqual(stitcher.segments.count, 1)
    }

    func testAMovingPartOnlyChangesNothing() {
        // A spinner in the middle changes while nothing scrolls.
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0], stitcher: &stitcher)
        var bytes = Fixtures.bytes(of: page.frameImage(offset: 0, scrollingHeight: scrolling))
        for row in 100 ..< 104 {
            for column in 0 ..< 10 { bytes[(row * page.width + column) * 4] ^= 0xFF }
        }
        let frame = Fixtures.Pixels(width: page.width, height: scrolling, bytes: bytes).makeImage(space: Fixtures.space)!

        XCTAssertEqual(stitcher.add(ScrollFrame(image: frame)!), .unchanged)
    }

    // MARK: Doubtful segments

    func testASegmentThatOnlyPartlyLinesUpIsFlagged() throws {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0], stitcher: &stitcher)
        // Part of the overlap changed between the frames, as when a video plays in the page.
        var bytes = Fixtures.bytes(of: page.frameImage(offset: 120, scrollingHeight: scrolling))
        for row in 40 ..< 70 {
            for column in 0 ..< page.width {
                let offset = (row * page.width + column) * 4
                for channel in 0 ..< 3 { bytes[offset + channel] = 255 - bytes[offset + channel] }
            }
        }
        let frame = Fixtures.Pixels(width: page.width, height: scrolling, bytes: bytes).makeImage(space: Fixtures.space)!

        XCTAssertEqual(stitcher.add(ScrollFrame(image: frame)!), .appended(rows: 120, suspicious: true))
        XCTAssertEqual(stitcher.segments.map(\.isSuspicious), [false, true])
    }

    func testAShiftOnlyBlankRowsConfirmIsFlagged() {
        // A plain page: nothing to vote with, so only the estimator's shift can be used.
        let blank = Fixtures.solid(width: 64, height: 200, gray: 240)
        var stitcher = ScrollStitcher(estimator: Estimator([50]))
        XCTAssertEqual(stitcher.add(ScrollFrame(image: blank)!), .started)
        var bytes = Fixtures.bytes(of: blank)
        // A slightly different first row: changed, but still too plain to align on.
        for column in 0 ..< 64 {
            for channel in 0 ..< 3 { bytes[column * 4 + channel] = 234 }
        }
        let moved = Fixtures.Pixels(width: 64, height: 200, bytes: bytes).makeImage(space: Fixtures.space)!

        XCTAssertEqual(stitcher.add(ScrollFrame(image: moved)!), .appended(rows: 50, suspicious: true))
    }

    // MARK: Redrawn content

    /// The frame at `offset`, with every gray level nudged by up to ±`noise`: the same content,
    /// rasterized again, so no row hash matches.
    private func redrawn(_ page: Fixtures.Page, offset: Int, noise: Int, seed: UInt64) -> ScrollFrame {
        var generator = Fixtures.Generator(state: seed)
        var bytes = Fixtures.bytes(of: page.frameImage(offset: offset, scrollingHeight: scrolling))
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let delta = Int(generator.next() % UInt64(noise * 2 + 1)) - noise
            for channel in 0 ..< 3 { bytes[index + channel] = UInt8(max(0, min(255, Int(bytes[index + channel]) + delta))) }
        }
        let image = Fixtures.Pixels(width: page.width, height: scrolling, bytes: bytes).makeImage(space: Fixtures.space)!
        return ScrollFrame(image: image)!
    }

    func testRedrawnContentStillLinesUp() throws {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(page.frame(offset: 0, scrollingHeight: scrolling)), .started)
        let next = redrawn(page, offset: 140, noise: 3, seed: 5)
        XCTAssertNil(ScrollStitcher.votedShift(previous: page.frame(offset: 0, scrollingHeight: scrolling).signature,
                                               current: next.signature, middle: 0 ..< scrolling),
                     "No row hash survives the redraw")

        XCTAssertEqual(stitcher.add(next), .appended(rows: 140, suspicious: false))
        XCTAssertEqual(stitcher.add(redrawn(page, offset: 260, noise: 3, seed: 6)), .appended(rows: 120, suspicious: false))
        XCTAssertEqual(stitcher.height, 260 + scrolling)
    }

    func testTheSearchFindsTheShiftByRowDistance() {
        let page = Fixtures.page()
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let moved = redrawn(page, offset: 90, noise: 2, seed: 9).signature

        XCTAssertEqual(ScrollStitcher.searchedShifts(previous: first, current: moved, middle: 0 ..< scrolling).first, 90)
        XCTAssertEqual(ScrollStitcher.searchedShifts(previous: moved, current: first, middle: 0 ..< scrolling).first, -90)
        let blank = ScrollFrame(image: Fixtures.solid(width: 96, height: scrolling, gray: 200))!.signature
        XCTAssertEqual(ScrollStitcher.searchedShifts(previous: blank, current: blank, middle: 0 ..< scrolling), [],
                     "Nothing detailed to compare")
        XCTAssertEqual(ScrollStitcher.searchedShifts(previous: first, current: moved, middle: 0 ..< 0), [])
    }

    /// Lines of code look alike in the coarse profiles: here they point 5 rows past the real shift,
    /// which only the fine boxes show.
    func testTheSearchSettlesTheCoarseShiftWithTheFineBoxes() {
        let height = 200, bins = 4, samples = 8
        var generator = Fixtures.Generator(state: 77)
        func rows(_ count: Int, _ width: Int) -> [[UInt8]] {
            (0 ..< count).map { _ in (0 ..< width).map { _ in UInt8(generator.next() % 256) } }
        }
        let fine = rows(height + 40, samples), coarse = rows(height + 45, bins)
        func signature(fineFrom fineStart: Int, coarseFrom coarseStart: Int) -> ScrollFrameSignature {
            ScrollFrameSignature(width: 64, height: height, hashes: (0 ..< height).map { UInt64($0) },
                                 isDetailed: Array(repeating: true, count: height),
                                 profiles: Array(coarse[coarseStart ..< coarseStart + height].joined()), bins: bins,
                                 fine: Array(fine[fineStart ..< fineStart + height].joined()), samples: samples)
        }
        let previous = signature(fineFrom: 0, coarseFrom: 0)
        let current = signature(fineFrom: 40, coarseFrom: 45)

        XCTAssertEqual(ScrollStitcher.searchedShifts(previous: previous, current: current, middle: 0 ..< height).first, 40)
    }

    /// A list whose layout repeats every 60 rows; only a narrow label at the left differs from item to item.
    private func repeatingPage(height: Int = 1200) -> Fixtures.Page {
        let base = Fixtures.page(width: 96, height: 60, seed: 21)
        var generator = Fixtures.Generator(state: 33)
        var bytes: [UInt8] = []
        for row in 0 ..< height {
            var line = Array(base.bytes[(row % 60) * 96 * 4 ..< (row % 60 + 1) * 96 * 4])
            for column in 0 ..< 6 {
                let value = UInt8(generator.next() % 200)
                line[column * 4] = value
                line[column * 4 + 1] = value
                line[column * 4 + 2] = value
            }
            bytes += line
        }
        return Fixtures.Page(width: 96, height: height, bytes: bytes)
    }

    func testARepeatingLayoutDoesNotFoolTheAlignment() throws {
        let page = repeatingPage()
        // The estimator offers the shift one item too short, where only the labels differ.
        var stitcher = ScrollStitcher(estimator: Estimator([-20]))
        XCTAssertEqual(stitcher.add(page.frame(offset: 0, scrollingHeight: scrolling)), .started)

        XCTAssertEqual(stitcher.add(page.frame(offset: 40, scrollingHeight: scrolling)),
                       .appended(rows: 40, suspicious: false))
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let second = page.frame(offset: 40, scrollingHeight: scrolling).signature
        let wrong = try XCTUnwrap(ScrollStitcher.evaluate(shift: -20, previous: first, current: second,
                                                          middle: 0 ..< scrolling))
        // Close on average, but every item's label gives the wrong shift away.
        XCTAssertLessThanOrEqual(wrong.distance, Double(ScrollFrameSignature.rowTolerance))
        XCTAssertLessThan(wrong.ratio, ScrollStitcher.acceptableMatchRatio)
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 40, scrollingHeight: scrolling))
    }

    func testCandidatesRankByDistanceThenMatchesThenSize() {
        let page = Fixtures.page()
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let second = page.frame(offset: 60, scrollingHeight: scrolling).signature

        let best = ScrollStitcher.best(of: [61, 60, 59, 400], fixed: (0, 0), widening: .none, previous: first,
                                       current: second)

        XCTAssertEqual(best?.candidate.shift, 60)
        XCTAssertEqual(best?.candidate.ratio, 1)
        XCTAssertEqual(best?.candidate.distance, 0)
        XCTAssertNil(ScrollStitcher.best(of: [], fixed: (0, 0), widening: .none, previous: first, current: second))
        XCTAssertNil(ScrollStitcher.evaluate(shift: 400, previous: first, current: second, middle: 0 ..< scrolling),
                     "No overlap")
        let close = ScrollStitcher.Candidate(shift: 9, ratio: 0.8, distance: 1, isAmbiguous: false)
        XCTAssertTrue(ScrollStitcher.isBetter(close, than: .init(shift: 1, ratio: 1, distance: 2, isAmbiguous: false)))
        XCTAssertTrue(ScrollStitcher.isBetter(close, than: .init(shift: 1, ratio: 0.7, distance: 1, isAmbiguous: false)))
        XCTAssertTrue(ScrollStitcher.isBetter(.init(shift: -2, ratio: 0.8, distance: 1, isAmbiguous: false), than: close))
    }

    /// A header with something moving in it in the first frame only (a spinner, a badge): its rows
    /// differ, so it does not count as pinned until the first shift is found.
    func testAnAnimatedHeaderStillLetsTheFirstScrollLineUp() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var bytes = Fixtures.bytes(of: page.frameImage(offset: 0, scrollingHeight: scrolling))
        for row in 0 ..< 10 {
            for column in 80 ..< 96 {
                let offset = (row * page.width + column) * 4
                for channel in 0 ..< 3 { bytes[offset + channel] = 255 - bytes[offset + channel] }
            }
        }
        let first = Fixtures.Pixels(width: page.width, height: 300, bytes: bytes).makeImage(space: Fixtures.space)!
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(ScrollFrame(image: first)!), .started)

        XCTAssertEqual(stitcher.add(page.frame(offset: 150, scrollingHeight: scrolling)),
                       .appended(rows: 150, suspicious: false))
        XCTAssertEqual(stitcher.headerHeight, 30)
        XCTAssertEqual(stitcher.add(page.frame(offset: 300, scrollingHeight: scrolling)),
                       .appended(rows: 150, suspicious: false))
    }

    func testTheStepJustScrolledIsOneMoreCandidate() {
        // A plain page: neither the vote nor the search has anything to go on.
        let blank = Fixtures.solid(width: 64, height: 200, gray: 240)
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(ScrollFrame(image: blank)!), .started)
        var bytes = Fixtures.bytes(of: blank)
        for column in 0 ..< 64 {
            for channel in 0 ..< 3 { bytes[column * 4 + channel] = 234 }
        }
        let moved = ScrollFrame(image: Fixtures.Pixels(width: 64, height: 200, bytes: bytes)
            .makeImage(space: Fixtures.space)!)!

        XCTAssertEqual(stitcher.add(moved), .unaligned)
        XCTAssertEqual(stitcher.add(moved, expectedShift: 40), .appended(rows: 40, suspicious: true))
    }

    // MARK: Estimator

    func testTheEstimatorsShiftIsCheckedAndAWrongOneIsOverruled() throws {
        let page = Fixtures.page()
        let estimator = Estimator([77, -77])
        var stitcher = ScrollStitcher(estimator: estimator)

        let outcomes = stitch(page, offsets: [0, 120, 240], stitcher: &stitcher)

        XCTAssertEqual(Array(outcomes.dropFirst()), Array(repeating: .appended(rows: 120, suspicious: false), count: 2))
        XCTAssertEqual(estimator.sizes.count, 2)
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 240, scrollingHeight: scrolling))
    }

    func testTheEstimatorOnlySeesTheScrollingRows() {
        let page = Fixtures.page(header: 30, footer: 20)
        let estimator = Estimator([120])
        var stitcher = ScrollStitcher(estimator: estimator)

        _ = stitch(page, offsets: [0, 120, 240], stitcher: &stitcher)

        // Only the rows between the pinned bars, which move.
        XCTAssertEqual(estimator.sizes.map(\.0), [250, 250])
    }

    func testAfterAnUndoTheVoteAlignsWithoutTheEstimator() throws {
        let page = Fixtures.page()
        let estimator = Estimator([120])
        var stitcher = ScrollStitcher(estimator: estimator)
        _ = stitch(page, offsets: [0, 120, 240], stitcher: &stitcher)

        XCTAssertTrue(stitcher.removeLastSegment())
        XCTAssertEqual(stitcher.height, 120 + scrolling)
        XCTAssertEqual(stitcher.add(page.frame(offset: 200, scrollingHeight: scrolling)),
                       .appended(rows: 80, suspicious: false))

        XCTAssertEqual(estimator.sizes.count, 2, "No reference image right after the undo")
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 200, scrollingHeight: scrolling))
    }

    func testUndoKeepsThePinnedBars() throws {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher()
        _ = stitch(page, offsets: [0, 120], stitcher: &stitcher)

        XCTAssertTrue(stitcher.removeLastSegment())
        XCTAssertEqual(stitcher.footerHeight, 20)
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 0, scrollingHeight: scrolling))
        XCTAssertEqual(stitcher.add(page.frame(offset: 100, scrollingHeight: scrolling)),
                       .appended(rows: 100, suspicious: false))
        XCTAssertEqual(Fixtures.bytes(of: try XCTUnwrap(stitcher.makeImage())),
                       page.expected(lastOffset: 100, scrollingHeight: scrolling))
    }

    // MARK: Size limit

    func testTheSizeLimitStopsAtThePixelBudget() throws {
        let page = Fixtures.page()
        // Room for 500 rows.
        var stitcher = ScrollStitcher(maxPixels: page.width * 500)

        let outcomes = stitch(page, offsets: [0, 120, 240, 360, 480], stitcher: &stitcher)

        XCTAssertEqual(outcomes, [.started, .appended(rows: 120, suspicious: false),
                                  .appended(rows: 120, suspicious: false), .reachedLimit(rows: 10),
                                  .reachedLimit(rows: 0)])
        XCTAssertTrue(stitcher.isFull)
        XCTAssertEqual(stitcher.pixelCount, page.width * 500)
        let image = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 250, scrollingHeight: scrolling))

        XCTAssertTrue(stitcher.removeLastSegment())
        XCTAssertFalse(stitcher.isFull)
    }

    func testTheLimitCountsTheBottomBar() {
        let page = Fixtures.page(header: 30, footer: 20)
        var stitcher = ScrollStitcher(maxPixels: page.width * 430)

        let outcomes = stitch(page, offsets: [0, 120, 240], stitcher: &stitcher)

        // 300 + 120 rows, then room for 10 more: the 20-row bottom bar is part of the budget.
        XCTAssertEqual(outcomes, [.started, .appended(rows: 120, suspicious: false), .reachedLimit(rows: 10)])
        XCTAssertEqual(stitcher.height, 430)
    }

    func testAFrameAtTheLimitIsFullAtOnce() {
        let page = Fixtures.page()
        var stitcher = ScrollStitcher(maxPixels: page.width * scrolling)

        XCTAssertEqual(stitch(page, offsets: [0, 120], stitcher: &stitcher), [.started, .reachedLimit(rows: 0)])
    }

    // MARK: Rows

    func testFixedRowsAreThoseThatKeptPlaceAndContent() {
        let page = Fixtures.page(header: 30, footer: 20)
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let second = page.frame(offset: 120, scrollingHeight: scrolling).signature

        let fixed = ScrollStitcher.fixedRows(first, second)

        XCTAssertEqual(fixed.header, 30)
        XCTAssertEqual(fixed.footer, 20)
        // Identical frames: capped at a third each.
        let same = ScrollStitcher.fixedRows(first, first)
        XCTAssertEqual(same.header, 100)
        XCTAssertEqual(same.footer, 100)
    }

    func testTheVoteFindsTheShift() {
        let page = Fixtures.page()
        let first = page.frame(offset: 0, scrollingHeight: scrolling).signature
        let second = page.frame(offset: 90, scrollingHeight: scrolling).signature

        XCTAssertEqual(ScrollStitcher.votedShift(previous: first, current: second, middle: 0 ..< scrolling), 90)
        XCTAssertEqual(ScrollStitcher.votedShift(previous: second, current: first, middle: 0 ..< scrolling), -90)
        let blank = ScrollFrame(image: Fixtures.solid(width: 96, height: scrolling, gray: 200))!.signature
        XCTAssertNil(ScrollStitcher.votedShift(previous: blank, current: blank, middle: 0 ..< scrolling))
    }

    func testCopiedRowsAreChecked() {
        let image = Fixtures.solid(width: 4, height: 10, gray: 9)
        XCTAssertNil(ScrollStitcher.copyRows(of: image, from: 0, count: 0))
        XCTAssertNil(ScrollStitcher.copyRows(of: image, from: -1, count: 2))
        XCTAssertNil(ScrollStitcher.copyRows(of: image, from: 8, count: 3))
        XCTAssertEqual(ScrollStitcher.copyRows(of: image, from: 8, count: 2)?.height, 2)
    }
}

final class ScrollFrameSignatureTests: XCTestCase {
    func testRowsAreHashedProfiledAndRatedForDetail() {
        let page = ScrollCaptureFixtures.page(width: 64, height: 40)
        let frame = page.frame(offset: 0, scrollingHeight: 40)
        let signature = frame.signature

        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 40)
        XCTAssertEqual(signature.width, 64)
        XCTAssertEqual(signature.height, 40)
        XCTAssertEqual(signature.bins, ScrollFrameSignature.profileBins)
        XCTAssertEqual(signature.profiles.count, 40 * signature.bins)
        XCTAssertTrue(signature.isDetailed[0], "A line of marks")
        XCTAssertFalse(signature.isDetailed[15], "A gap")
        XCTAssertNotEqual(signature.hashes[0], signature.hashes[1])
        XCTAssertTrue(signature.row(3, matches: 3, of: signature))
        XCTAssertFalse(signature.row(0, matches: 1, of: signature))
    }

    func testCloseRowsMatchWithinTheTolerance() {
        // 16 columns, of which the last two are left out as the scroll bar's.
        let row: [UInt8] = Array(repeating: 100, count: 8) + Array(repeating: 200, count: 8)
        let near = row.map { $0 + 4 }
        let far = row.map { $0 - 40 }
        // Two boxes off by a little, the rest the same: as when glyphs are drawn again a little differently.
        let partly = [140, 150] + Array(row[2...])
        let signature = ScrollFrameSignature(gray: row + near + far + partly, width: 16, height: 4)

        XCTAssertEqual(ScrollFrameSignature.comparedWidth(16), 14)
        XCTAssertEqual(signature.bins, 14, "Never more bins than compared columns")
        XCTAssertTrue(signature.row(0, matches: 1, of: signature))
        XCTAssertEqual(signature.distance(0, to: 1, of: signature), 4)
        XCTAssertFalse(signature.row(0, matches: 2, of: signature))
        XCTAssertEqual(signature.distance(0, to: 2, of: signature), 40)
        XCTAssertTrue(signature.row(0, matches: 3, of: signature), "On average close enough")
        // Close on average, but one box far off: a different label.
        let label = [184] + Array(row[1...])
        let labelled = ScrollFrameSignature(gray: row + label, width: 16, height: 2)
        XCTAssertLessThanOrEqual(labelled.distance(0, to: 1, of: labelled), ScrollFrameSignature.rowTolerance)
        XCTAssertFalse(labelled.row(0, matches: 1, of: labelled))
        let other = ScrollFrameSignature(gray: Array(repeating: 100, count: 64), width: 64, height: 1)
        XCTAssertFalse(signature.row(0, matches: 0, of: other), "Different bins never match loosely")
        XCTAssertEqual(signature.distance(0, to: 0, of: other), 255)
        XCTAssertEqual(signature.profileDistance(0, to: 1, of: signature), 4)
        XCTAssertEqual(signature.profileDistance(0, to: 0, of: other), 255)
        XCTAssertEqual(signature.samples, 14)
        XCTAssertEqual(signature.fine.count, 4 * 14)
        // The scroll bar's columns do not count.
        let scrolled = ScrollFrameSignature(gray: row + Array(row[0 ..< 14]) + [0, 0], width: 16, height: 2)
        XCTAssertEqual(scrolled.hashes[0], scrolled.hashes[1])
    }

    func testGrayPixelsReadTheImage() throws {
        let image = ScrollCaptureFixtures.solid(width: 3, height: 2, gray: 128)
        let gray = try XCTUnwrap(ScrollFrameSignature.grayPixels(of: image))

        XCTAssertEqual(gray.count, 6)
        XCTAssertTrue(gray.allSatisfy { abs(Int($0) - 128) <= 8 })
    }
}

final class VisionScrollOffsetEstimatorTests: XCTestCase {
    func testBothDirectionsAreProposed() {
        XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: 0.3), [0])
        XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: 41.6), [42, -42])
        XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: -12), [-12, 12])
        XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: .nan), [])
    }

    func testVisionProposesTheShiftOfAScrolledPage() {
        let page = ScrollCaptureFixtures.page(width: 200, height: 900)
        let before = page.frameImage(offset: 0, scrollingHeight: 400)
        let after = page.frameImage(offset: 120, scrollingHeight: 400)

        let shifts = VisionScrollOffsetEstimator().verticalShifts(from: before, to: after)

        XCTAssertTrue(shifts.contains(120), "Vision proposed \(shifts)")
        // The stitcher keeps the right one.
        var stitcher = ScrollStitcher(estimator: VisionScrollOffsetEstimator())
        XCTAssertEqual(stitcher.add(ScrollFrame(image: before)!), .started)
        XCTAssertEqual(stitcher.add(ScrollFrame(image: after)!), .appended(rows: 120, suspicious: false))
    }
}
