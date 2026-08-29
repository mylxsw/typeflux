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

    func testProgressQuicklyReachesHalfBeforeSlowerSecondStage() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertGreaterThan(timeline.progress(elapsed: 0.5), 0.3)
        XCTAssertEqual(
            timeline.progress(elapsed: ProcessingProgressTimeline.initialStageDuration),
            ProcessingProgressTimeline.initialStageProgress,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            timeline.progress(elapsed: ProcessingProgressTimeline.initialStageDuration + 1),
            ProcessingProgressTimeline.initialStageProgress
        )
    }

    func testProgressWaitsAtHalfUntilContentProcessingStarts() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(
            timeline.progress(elapsed: 30, contentProcessingStartedAt: nil),
            ProcessingProgressTimeline.initialStageProgress,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            timeline.progress(elapsed: 30, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.initialStageProgress,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            timeline.progress(elapsed: 31, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.initialStageProgress
        )
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
        let earlyGain = timeline.progress(elapsed: 1.5) - timeline.progress(elapsed: 0)
        let lateGain = timeline.progress(elapsed: 120) - timeline.progress(elapsed: 90)

        XCTAssertGreaterThan(earlyGain, lateGain)
        XCTAssertGreaterThan(lateGain, 0)
    }

    func testShortTimeoutStillUsesBothStagesAndReachesIncompleteMaximum() {
        let timeline = ProcessingProgressTimeline(timeout: 1)

        XCTAssertEqual(timeline.progress(elapsed: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(timeline.progress(elapsed: 0.75), 0.5)
        XCTAssertEqual(
            timeline.progress(elapsed: 1),
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
    }

    func testNonPositiveTimeoutRemainsFinite() {
        let timeline = ProcessingProgressTimeline(timeout: 0)
        let progress = timeline.progress(elapsed: 1)

        XCTAssertTrue(progress.isFinite)
        XCTAssertEqual(progress, ProcessingProgressTimeline.maximumIncompleteProgress, accuracy: 0.0001)
    }
}
