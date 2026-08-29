@testable import Typeflux
import XCTest

final class ProcessingProgressTimelineTests: XCTestCase {
    func testRecognitionStartsAtHalfAndClampsNegativeElapsedTime() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(
            timeline.progress(elapsed: -1, contentProcessingStartedAt: nil),
            ProcessingProgressTimeline.initialProgress
        )
        XCTAssertEqual(
            timeline.progress(elapsed: 0, contentProcessingStartedAt: nil),
            ProcessingProgressTimeline.initialProgress
        )
    }

    func testRecognitionContinuouslyApproachesSeventyPercent() {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        let checkpoints = stride(from: 0.0, through: 10.0, by: 0.1)
            .map { timeline.progress(elapsed: $0, contentProcessingStartedAt: nil) }

        for (earlier, later) in zip(checkpoints, checkpoints.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
        XCTAssertGreaterThan(checkpoints[5], 0.6)
        XCTAssertLessThan(checkpoints.last!, ProcessingProgressTimeline.recognitionCompleteProgress)
    }

    func testContentProcessingStartsAtSeventyPercentAndContinuesForward() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(
            timeline.progress(elapsed: 30, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.recognitionCompleteProgress,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            timeline.progress(elapsed: 31, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.recognitionCompleteProgress
        )
    }

    func testContentProgressContinuouslyAdvancesAcrossRemainingTimeout() {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        let checkpoints = stride(from: 30.0, through: 120.0, by: 1.0)
            .map { timeline.progress(elapsed: $0, contentProcessingStartedAt: 30) }

        for (earlier, later) in zip(checkpoints, checkpoints.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
    }

    func testIncompleteContentProgressNeverReachesCompletion() {
        let timeline = ProcessingProgressTimeline(timeout: 120)

        XCTAssertEqual(
            timeline.progress(elapsed: 120, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            timeline.progress(elapsed: 300, contentProcessingStartedAt: 30),
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            timeline.progress(elapsed: 300, contentProcessingStartedAt: 30),
            1
        )
    }

    func testContentProgressSlowsDownWithoutStoppingNearTimeout() {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        let earlyGain = timeline.progress(elapsed: 60, contentProcessingStartedAt: 30)
            - timeline.progress(elapsed: 30, contentProcessingStartedAt: 30)
        let lateGain = timeline.progress(elapsed: 120, contentProcessingStartedAt: 30)
            - timeline.progress(elapsed: 90, contentProcessingStartedAt: 30)

        XCTAssertGreaterThan(earlyGain, lateGain)
        XCTAssertGreaterThan(lateGain, 0)
    }

    func testNonPositiveTimeoutRemainsFinite() {
        let timeline = ProcessingProgressTimeline(timeout: 0)
        let progress = timeline.progress(elapsed: 1, contentProcessingStartedAt: 0)

        XCTAssertTrue(progress.isFinite)
        XCTAssertEqual(
            progress,
            ProcessingProgressTimeline.maximumIncompleteProgress,
            accuracy: 0.0001
        )
    }
}
