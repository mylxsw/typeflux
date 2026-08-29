@testable import Typeflux
import XCTest

final class ProcessingProgressTimelineTests: XCTestCase {
    func testProgressStartsAtZeroAndClampsNegativeElapsedTime() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(timeline.progress(elapsed: -1), 0)
        XCTAssertEqual(timeline.progress(elapsed: 0), 0)
    }

    func testProgressContinuouslyAdvancesAcrossEntireTimeout() {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        let checkpoints = stride(from: 0.0, through: 120.0, by: 1.0)
            .map(timeline.progress(elapsed:))

        for (earlier, later) in zip(checkpoints, checkpoints.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
    }

    func testIncompleteProgressNeverReachesCompletion() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(
            timeline.progress(elapsed: 120),
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            timeline.progress(elapsed: 300),
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
        XCTAssertLessThan(timeline.progress(elapsed: 300), 1)
    }

    func testProgressSlowsDownWithoutStoppingNearTimeout() {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        let earlyGain = timeline.progress(elapsed: 30) - timeline.progress(elapsed: 0)
        let lateGain = timeline.progress(elapsed: 120) - timeline.progress(elapsed: 90)

        XCTAssertGreaterThan(earlyGain, lateGain)
        XCTAssertGreaterThan(lateGain, 0)
    }

    func testNonPositiveTimeoutRemainsFinite() {
        let timeline = ProcessingProgressTimeline(timeout: 0)
        let progress = timeline.progress(elapsed: 1)

        XCTAssertTrue(progress.isFinite)
        XCTAssertEqual(progress, ProcessingProgressTimeline.maximumIncompleteProgress, accuracy: 0.0001)
    }
}
