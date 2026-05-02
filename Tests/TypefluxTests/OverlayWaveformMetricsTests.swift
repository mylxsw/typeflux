@testable import Typeflux
import XCTest

final class OverlayWaveformMetricsTests: XCTestCase {
    func testSpeakingLevelsProduceNoticeablyTallerCenterBar() {
        let quietHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0)
        let speakingHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0.2)

        XCTAssertGreaterThan(speakingHeight - quietHeight, 3.5)
    }

    func testLevelsClampToCapsuleWaveformBounds() {
        let minimumHeight = OverlayWaveformMetrics.barHeight(for: 4, level: -1)
        let zeroHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0)
        let maximumHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 2)

        XCTAssertEqual(minimumHeight, zeroHeight, accuracy: 0.001)
        XCTAssertEqual(maximumHeight, 15.0, accuracy: 0.001)
    }

    func testProfileKeepsOuterBarsShorterThanCenter() {
        let centerHeight = OverlayWaveformMetrics.barHeight(for: 4, level: 0.6)
        let outerHeight = OverlayWaveformMetrics.barHeight(for: 8, level: 0.6)

        XCTAssertLessThan(outerHeight, centerHeight)
    }
}
