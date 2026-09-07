@testable import Typeflux
import XCTest

final class OverlayWaveformMetricsTests: XCTestCase {
    func testSoftSpeechIsVisibleAboveTheQuietBaseline() {
        let quietHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0)
        let speakingHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0.2)

        XCTAssertGreaterThan(speakingHeight - quietHeight, 4.6)
    }

    func testNormalSpeechHasRoomForVisibleVolumeChanges() {
        let softerHeight = OverlayWaveformMetrics.barHeight(for: 4, level: level(decibels: -45))
        let louderHeight = OverlayWaveformMetrics.barHeight(for: 4, level: level(decibels: -35))

        XCTAssertGreaterThan(louderHeight - softerHeight, 5)
        XCTAssertLessThan(louderHeight, OverlayWaveformMetrics.maximumBarHeight - 5)
    }

    func testQuietInputStaysLowAndSpeechSettlesBackToBaseline() {
        let quietHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0)
        let belowDisplayFloor = OverlayWaveformMetrics.barHeight(for: 4, level: level(decibels: -56))
        let heights = [-60, -48, -35, -20, -60].map {
            OverlayWaveformMetrics.barHeight(for: 4, level: level(decibels: Float($0)))
        }

        XCTAssertEqual(belowDisplayFloor, quietHeight)
        XCTAssertLessThanOrEqual(quietHeight, 3)
        XCTAssertEqual(heights.first, heights.last)
        XCTAssertGreaterThan(heights[3] - heights[0], 19)
    }

    func testLevelsClampToCapsuleWaveformBounds() {
        let minimumHeight = OverlayWaveformMetrics.barHeight(for: 4, level: -1)
        let zeroHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0)
        let maximumHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 2)

        XCTAssertEqual(minimumHeight, zeroHeight, accuracy: 0.001)
        XCTAssertEqual(maximumHeight, 24.0, accuracy: 0.001)
    }

    func testAllBarsStayFiniteAndInsideCapsuleAcrossInputRange() {
        let levels: [Float] = [-.infinity, -1, 0, 0.1, 0.2, 0.4, 0.7, 1, 2, .infinity, .nan]
        for index in 0 ..< OverlayWaveformMetrics.barCount {
            for level in levels {
                let height = OverlayWaveformMetrics.barHeight(for: index, level: level)
                XCTAssertTrue(height.isFinite)
                XCTAssertGreaterThanOrEqual(height, 3)
                XCTAssertLessThanOrEqual(height, 24)
            }
        }
    }

    func testProfileKeepsOuterBarsShorterThanCenter() {
        let centerHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0.6)
        let outerHeight = OverlayWaveformMetrics.barHeight(for: 8, level: 0.6)

        XCTAssertLessThan(outerHeight, centerHeight)
    }

    private func level(decibels: Float) -> Float {
        (decibels + 60) / 60
    }
}
