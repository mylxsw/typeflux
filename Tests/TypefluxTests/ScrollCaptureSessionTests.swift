// swiftlint:disable file_length type_body_length
import CoreGraphics
@testable import Typeflux
import XCTest

@MainActor
final class ScrollCaptureSessionTests: XCTestCase {
    private typealias Fixtures = ScrollCaptureFixtures

    private struct StreamFailure: Error {}

    private final class Source: ScrollFrameSource, @unchecked Sendable {
        var startError: Error?
        private(set) var started: [ScrollCaptureRegion] = []
        private(set) var stops = 0
        var onError: (@Sendable (Error) -> Void)?

        func start(_ region: ScrollCaptureRegion, onFrame: @escaping @Sendable (CGImage) -> Void,
                   onError: @escaping @Sendable (Error) -> Void) async throws {
            started.append(region)
            self.onError = onError
            if let startError { throw startError }
        }

        func stop() { stops += 1 }
    }

    private final class Driver: ScrollDriving {
        var canScroll = true
        var anchor: CGPoint?
        private(set) var begins: [CGRect] = []
        private(set) var scrolls: [CGFloat] = []
        private(set) var ends = 0

        func begin(in region: CGRect) {
            begins.append(region)
            anchor = CGPoint(x: region.midX, y: region.midY)
        }

        func scroll(by points: CGFloat) { scrolls.append(points) }
        func end() { ends += 1 }
    }

    private final class Monitor: ScrollUserActivityMonitoring {
        var handler: ((ScrollUserActivity) -> Void)?
        private(set) var stops = 0

        func start(_ handler: @escaping (ScrollUserActivity) -> Void) { self.handler = handler }
        func stop() {
            stops += 1
            handler = nil
        }
    }

    private final class Presenter: ScrollCapturePresenting {
        private(set) var presented: ScrollCaptureRegion?
        var actions: ScrollCaptureActions?
        private(set) var states: [ScrollCaptureViewState] = []
        private(set) var previews: [ScrollCapturePreview] = []
        private(set) var dismissals = 0

        func present(_ region: ScrollCaptureRegion, actions: ScrollCaptureActions) {
            presented = region
            self.actions = actions
        }

        func update(_ state: ScrollCaptureViewState, preview: ScrollCapturePreview) {
            states.append(state)
            previews.append(preview)
        }

        func dismiss() { dismissals += 1 }
    }

    private let source = Source()
    private let driver = Driver()
    private let monitor = Monitor()
    private let presenter = Presenter()
    private var clock = Date(timeIntervalSince1970: 1000)
    private var tickAction: (@MainActor () -> Void)?
    private var tickingStopped = false
    private var results: [ScrollCaptureResult] = []
    private var accessibilityRequests = 0
    private let page = Fixtures.page(header: 0, footer: 0)
    /// 125 points at 2×: 250 rows per frame.
    private let region = ScrollCaptureRegion(displayID: 7, displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                             scale: 2, rect: CGRect(x: 100, y: 50, width: 48, height: 125))

    private func makeSession(maxPixels: Int = ScrollStitcher.defaultMaxPixels,
                             analyze: @escaping @Sendable (CGImage) -> ScrollFrame? = { ScrollFrame(image: $0) })
        -> ScrollCaptureSession {
        ScrollCaptureSession(
            region: region, source: source, driver: driver, monitor: monitor, presenter: presenter, estimator: nil,
            maxPixels: maxPixels, now: { [unowned self] in clock },
            schedule: { [unowned self] _, action in
                tickAction = action
                return { [unowned self] in tickingStopped = true }
            },
            openAccessibilitySettings: { [unowned self] in accessibilityRequests += 1 },
            analyze: analyze
        )
    }

    private func start(_ session: ScrollCaptureSession) async {
        session.start { [unowned self] in results.append($0) }
        await session.startTask?.value
    }

    private func frame(_ offset: Int) -> CGImage {
        page.frameImage(offset: offset, scrollingHeight: 250)
    }

    /// A tick, and the analysis it may have started.
    private func tick(_ session: ScrollCaptureSession) async {
        session.tick()
        await session.analysis?.value
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    /// A frame arrives and the picture then holds still.
    private func settle(_ session: ScrollCaptureSession, _ offset: Int) async {
        session.receive(frame(offset))
        advance(ScrollCaptureSession.quietInterval)
        await tick(session)
    }

    /// A step was sent and nothing moved.
    private func timeOut(_ session: ScrollCaptureSession) async {
        advance(ScrollCaptureSession.stepTimeout)
        await tick(session)
    }

    private var finishedImage: (CGImage, ScrollCaptureEnding)? {
        guard case let .finished(image, ending)? = results.last else { return nil }
        return (image, ending)
    }

    // MARK: Automatic scrolling

    func testScrollsStepByStepAndEndsAtTheBottom() async throws {
        let session = makeSession()
        await start(session)

        XCTAssertEqual(presenter.presented, region)
        XCTAssertEqual(source.started, [region])
        XCTAssertNotNil(monitor.handler)
        XCTAssertNotNil(tickAction)
        XCTAssertEqual(session.state.status, .starting)

        session.receive(frame(0))
        advance(0.1)
        await tick(session)
        XCTAssertTrue(driver.scrolls.isEmpty, "Waits for the picture to hold still")
        advance(ScrollCaptureSession.quietInterval)
        await tick(session)

        XCTAssertEqual(session.state.status, .scrolling)
        XCTAssertEqual(driver.begins, [region.rect])
        // 60% of 125 points.
        XCTAssertEqual(driver.scrolls, [75])

        await settle(session, 150)
        XCTAssertEqual(session.state.pixelSize, ScreenPixelSize(width: page.width, height: 400))
        XCTAssertTrue(session.state.canUndo)
        XCTAssertEqual(driver.scrolls, [75, 75])

        await settle(session, 300)
        await timeOut(session)
        await timeOut(session)
        XCTAssertTrue(results.isEmpty)
        await timeOut(session)

        let (image, ending) = try XCTUnwrap(finishedImage)
        XCTAssertEqual(ending, .reachedEnd)
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 300, scrollingHeight: 250))
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(tickingStopped)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(monitor.stops, 1)
        XCTAssertEqual(driver.ends, 1)
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testAnUnchangedFrameAfterAStepCountsTowardTheEnd() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        await settle(session, 120)

        await settle(session, 120)
        await settle(session, 120)
        XCTAssertTrue(results.isEmpty)
        await settle(session, 120)

        XCTAssertEqual(finishedImage?.1, .reachedEnd)
    }

    func testARegionThatNeverScrollsKeepsItsFirstFrame() async throws {
        let session = makeSession()
        await start(session)
        await settle(session, 0)

        await timeOut(session)
        await timeOut(session)
        await timeOut(session)

        let (image, ending) = try XCTUnwrap(finishedImage)
        XCTAssertEqual(ending, .cannotScroll)
        XCTAssertEqual(image.height, 250)
    }

    func testTheStepFollowsThePinnedBars() async {
        let page = Fixtures.page(header: 30, footer: 20)
        let session = makeSession()
        await start(session)
        session.receive(page.frameImage(offset: 0, scrollingHeight: 200))
        advance(ScrollCaptureSession.quietInterval)
        await tick(session)
        XCTAssertEqual(session.stepPoints, 75, "The whole region before the bars are known")

        session.receive(page.frameImage(offset: 100, scrollingHeight: 200))
        advance(ScrollCaptureSession.quietInterval)
        await tick(session)

        // 60% of the 200 scrolling rows, in points.
        XCTAssertEqual(session.stepPoints, 60)
        XCTAssertEqual(driver.scrolls.last, 60)
    }

    func testAPageThatNeverHoldsStillIsJoinedAnyway() async {
        let session = makeSession()
        await start(session)
        session.receive(frame(0))
        for _ in 0 ..< 7 {
            advance(0.2)
            session.receive(frame(0))
            await tick(session)
        }

        XCTAssertEqual(session.state.status, .scrolling)
    }

    // MARK: The user

    func testTheUsersMouseTakesOver() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        let anchor = try? XCTUnwrap(driver.anchor)

        monitor.handler?(.moved(CGPoint(x: (anchor?.x ?? 0) + 3, y: anchor?.y ?? 0)))
        XCTAssertEqual(session.state.status, .scrolling, "A tiny move is not the user taking over")
        monitor.handler?(.moved(CGPoint(x: 0, y: 0)))
        XCTAssertEqual(session.state.status, .pausedByMouse)
        let steps = driver.scrolls.count

        // Scrolling by hand is still joined; nothing is scrolled for the user.
        await settle(session, 100)
        XCTAssertEqual(session.state.pixelSize.height, 350)
        await settle(session, 100)
        await timeOut(session)
        await timeOut(session)
        await timeOut(session)
        XCTAssertEqual(driver.scrolls.count, steps)
        XCTAssertTrue(results.isEmpty, "Holding still while paused does not end the capture")

        presenter.actions?.togglePause()
        XCTAssertEqual(session.state.status, .scrolling)
        XCTAssertEqual(driver.begins.count, 2, "The pointer goes back into the region")
        await tick(session)
        XCTAssertEqual(driver.scrolls.count, steps + 1)
    }

    func testScrollingOrClickingPausesAndSpacePausesAndResumes() async {
        let session = makeSession()
        await start(session)
        presenter.actions?.togglePause()
        XCTAssertEqual(session.state.status, .starting, "Nothing to pause before the first frame")
        await settle(session, 0)

        monitor.handler?(.scrolled)
        XCTAssertEqual(session.state.status, .pausedByMouse)
        monitor.handler?(.clicked)
        XCTAssertEqual(session.state.status, .pausedByMouse)
        presenter.actions?.togglePause()
        monitor.handler?(.clicked)
        XCTAssertEqual(session.state.status, .pausedByMouse)

        presenter.actions?.togglePause()
        presenter.actions?.togglePause()
        XCTAssertEqual(session.state.status, .paused)
        XCTAssertFalse(session.state.isAutomatic)
        XCTAssertTrue(session.state.canToggleAutomatic)
    }

    func testWithoutAccessibilityOnlyScrollingByHandWorks() async throws {
        driver.canScroll = false
        let session = makeSession()
        await start(session)
        await settle(session, 0)

        XCTAssertEqual(session.state.status, .needsAccessibility)
        XCTAssertFalse(session.state.canToggleAutomatic)
        presenter.actions?.togglePause()
        XCTAssertEqual(session.state.status, .needsAccessibility)
        presenter.actions?.openAccessibilitySettings()
        XCTAssertEqual(accessibilityRequests, 1)

        await settle(session, 200)
        XCTAssertTrue(driver.scrolls.isEmpty)
        XCTAssertTrue(driver.begins.isEmpty)
        presenter.actions?.finish()

        let (image, ending) = try XCTUnwrap(finishedImage)
        XCTAssertEqual(ending, .user)
        XCTAssertEqual(Fixtures.bytes(of: image), page.expected(lastOffset: 200, scrollingHeight: 250))
    }

    func testFinishingJoinsTheFrameStillWaiting() async throws {
        driver.canScroll = false
        let session = makeSession()
        await start(session)
        await settle(session, 0)

        session.receive(frame(100))
        presenter.actions?.finish()

        XCTAssertEqual(try XCTUnwrap(finishedImage).0.height, 350)
        // Late input after the end does nothing.
        session.receive(frame(200))
        await tick(session)
        presenter.actions?.undo()
        presenter.actions?.togglePause()
        monitor.handler?(.clicked)
        session.cancel()
        XCTAssertEqual(results.count, 1)
    }

    // MARK: Problems

    func testFramesThatDoNotLineUpPauseAutomaticScrolling() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        let noise = { (seed: UInt64) in Fixtures.noise(width: self.page.width, height: 250, seed: seed) }

        for seed: UInt64 in 1 ... 3 {
            session.receive(noise(seed))
            advance(ScrollCaptureSession.quietInterval)
            await tick(session)
        }

        XCTAssertEqual(session.state.status, .misaligned)
        presenter.actions?.togglePause()
        XCTAssertEqual(session.state.status, .scrolling, "Space tries again")
    }

    func testAFlaggedSegmentShowsAndUndoScrollsBack() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        await settle(session, 150)
        var bytes = Fixtures.bytes(of: page.frameImage(offset: 300, scrollingHeight: 250))
        // Rows in the middle of the overlap, so they cannot pass for a band under a pinned header.
        for index in stride(from: page.width * 4 * 40, to: page.width * 4 * 65, by: 1) where index % 4 != 3 {
            bytes[index] = 255 - bytes[index]
        }
        session.receive(Fixtures.Pixels(width: page.width, height: 250, bytes: bytes).makeImage(space: Fixtures.space)!)
        advance(ScrollCaptureSession.quietInterval)
        await tick(session)
        XCTAssertTrue(session.state.lastSegmentSuspicious)
        let height = session.state.pixelSize.height

        presenter.actions?.undo()

        XCTAssertFalse(session.state.lastSegmentSuspicious)
        XCTAssertEqual(session.state.pixelSize.height, height - 150)
        // Back up by the dropped 150 rows: 75 points.
        XCTAssertEqual(driver.scrolls.last, -75)
        // The page is back where the previous frame was: that is not "nothing changed".
        await settle(session, 150)
        await timeOut(session)
        await timeOut(session)
        XCTAssertTrue(results.isEmpty)
    }

    func testUndoWhilePausedOnlyDropsTheSegment() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        presenter.actions?.undo()
        XCTAssertFalse(session.state.canUndo, "Nothing to undo yet")
        await settle(session, 150)
        presenter.actions?.togglePause()
        let steps = driver.scrolls.count

        presenter.actions?.undo()

        XCTAssertEqual(session.state.pixelSize.height, 250)
        XCTAssertEqual(driver.scrolls.count, steps)
    }

    func testTheSizeLimitEndsTheCapture() async throws {
        let session = makeSession(maxPixels: page.width * 400)
        await start(session)
        await settle(session, 0)
        await settle(session, 120)

        await settle(session, 240)

        let (image, ending) = try XCTUnwrap(finishedImage)
        XCTAssertEqual(ending, .reachedLimit)
        XCTAssertEqual(image.height, 400)
    }

    func testAStreamThatStopsKeepsWhatWasJoined() async throws {
        let session = makeSession()
        await start(session)
        await settle(session, 0)

        source.onError?(StreamFailure())
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(try XCTUnwrap(finishedImage).1, .interrupted)
    }

    func testAStreamThatStopsBeforeAnyFrameFails() async {
        let session = makeSession()
        await start(session)

        source.onError?(StreamFailure())
        await Task.yield()
        await Task.yield()

        guard case .failed? = results.last else { return XCTFail("Expected a failure, got \(results)") }
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testAStreamThatCannotStartFails() async {
        source.startError = StreamFailure()
        let session = makeSession()

        await start(session)

        guard case .failed? = results.last else { return XCTFail("Expected a failure, got \(results)") }
        XCTAssertFalse(session.isActive)
    }

    func testCancellingStopsEverything() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        session.start { _ in XCTFail("A second start is ignored") }

        presenter.actions?.cancel()

        guard case .cancelled? = results.last else { return XCTFail("Expected a cancel, got \(results)") }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(driver.ends, 1)
        XCTAssertEqual(presenter.dismissals, 1)
        presenter.actions?.finish()
        XCTAssertEqual(results.count, 1)
    }

    func testTheTimerTicksOnTheMainRunLoop() async {
        var ticks = 0
        let stop = ScrollCaptureSession.repeatingTimer(0.01) { ticks += 1 }
        let deadline = Date().addingTimeInterval(2)
        while ticks == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        stop()
        let after = ticks
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(after, 0)
        XCTAssertEqual(ticks, after, "Stopped")
    }

    // MARK: Analysis

    func testAnImageThatCannotBeAnalyzedIsSkipped() async {
        let session = makeSession(analyze: { _ in nil })
        await start(session)

        await settle(session, 0)

        XCTAssertTrue(session.stitcher.isEmpty)
        XCTAssertEqual(session.state.status, .starting)
        XCTAssertNil(session.analysis)
    }

    func testNothingTimesOutWhileAFrameIsAnalyzed() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        let steps = driver.scrolls.count
        session.receive(frame(150))
        advance(ScrollCaptureSession.quietInterval)
        // The analysis runs elsewhere and only reports back once this test lets the main actor go.
        session.tick()
        XCTAssertNotNil(session.analysis)

        for _ in 0 ..< 5 {
            advance(ScrollCaptureSession.stepTimeout)
            session.tick()
        }

        XCTAssertEqual(driver.scrolls.count, steps, "No step and no timeout while analyzing")
        await session.analysis?.value
        XCTAssertEqual(session.state.pixelSize.height, 400)
        XCTAssertTrue(results.isEmpty)
    }

    func testFinishingWhileAFrameIsAnalyzedStillJoinsIt() async throws {
        driver.canScroll = false
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        session.receive(frame(100))
        advance(ScrollCaptureSession.quietInterval)
        session.tick()
        XCTAssertNotNil(session.analysis)

        presenter.actions?.finish()

        XCTAssertEqual(try XCTUnwrap(finishedImage).0.height, 350)
        await session.analysis?.value
        XCTAssertEqual(results.count, 1, "The late analysis is dropped")
    }

    func testSomethingAlwaysMovingDoesNotHoldUpScrolling() async {
        let session = makeSession()
        await start(session)
        await settle(session, 0)
        XCTAssertEqual(driver.scrolls.count, 1)
        session.receive(frame(150))
        advance(ScrollCaptureSession.quietInterval)
        session.tick()
        // A blinking caret keeps frames coming while that frame is analyzed.
        session.receive(frame(150))

        await session.analysis?.value

        XCTAssertEqual(session.state.pixelSize.height, 400)
        XCTAssertEqual(driver.scrolls.count, 2, "The next step goes out anyway")
        // What was captured before the step does not count for it.
        advance(ScrollCaptureSession.stepTimeout)
        await tick(session)
        XCTAssertEqual(driver.scrolls.count, 3, "Nothing new arrived after the step: it timed out")
    }
}
