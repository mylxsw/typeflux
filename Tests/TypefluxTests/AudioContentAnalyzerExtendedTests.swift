import AVFoundation
import XCTest
@testable import Typeflux

final class AudioContentAnalyzerExtendedTests: XCTestCase {

    // MARK: - containsAudibleSignal via rmsPower threshold

    func testIsAudibleWhenRMSPowerAboveThreshold() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -40,
            peakPowerDB: -50,
            audibleDuration: 0,
            audibleFrameRatio: 0,
            frameCount: 16_000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testIsAudibleAtExactRMSThreshold() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -42,
            peakPowerDB: -50,
            audibleDuration: 0,
            audibleFrameRatio: 0,
            frameCount: 16_000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    // MARK: - containsAudibleSignal via peak + duration + ratio

    func testIsAudibleWhenPeakAboveThresholdWithSufficientDurationAndRatio() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -50,
            peakPowerDB: -30,
            audibleDuration: 0.1,
            audibleFrameRatio: 0.05,
            frameCount: 16_000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testIsNotAudibleWhenPeakAboveThresholdButDurationTooShort() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -50,
            peakPowerDB: -30,
            audibleDuration: 0.05,
            audibleFrameRatio: 0.05,
            frameCount: 16_000
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    func testIsNotAudibleWhenPeakAboveThresholdButRatioTooLow() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -50,
            peakPowerDB: -30,
            audibleDuration: 0.1,
            audibleFrameRatio: 0.03,
            frameCount: 16_000
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    // MARK: - Not audible

    func testIsNotAudibleWhenBothPowersBelowThresholds() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -60,
            peakPowerDB: -50,
            audibleDuration: 0.5,
            audibleFrameRatio: 0.5,
            frameCount: 16_000
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    func testIsNotAudibleWhenDurationIsZero() {
        let analysis = AudioContentAnalysis(
            duration: 0,
            rmsPowerDB: -10,
            peakPowerDB: -5,
            audibleDuration: 0,
            audibleFrameRatio: 0,
            frameCount: 0
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    // MARK: - Boundary conditions

    func testPeakExactlyAtThresholdWithSufficientDurationAndRatio() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -50,
            peakPowerDB: -35,
            audibleDuration: 0.08,
            audibleFrameRatio: 0.04,
            frameCount: 16_000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testRMSJustBelowThresholdFallsThroughToPeakCheck() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -42.01,
            peakPowerDB: -36,
            audibleDuration: 0.1,
            audibleFrameRatio: 0.05,
            frameCount: 16_000
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }
}
