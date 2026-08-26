import AVFoundation
@testable import Typeflux
import XCTest

final class AudioContentAnalyzerExtendedTests: XCTestCase {
    // MARK: - containsAudibleSignal via rmsPower threshold

    func testIsAudibleWhenRMSPowerAboveThreshold() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -40,
            peakPowerDB: -50,
            audibleDuration: 0,
            audibleFrameRatio: 0,
            frameCount: 16000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testIsAudibleAtExactRMSThreshold() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -48,
            peakPowerDB: -55,
            audibleDuration: 0,
            audibleFrameRatio: 0,
            frameCount: 16000
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
            frameCount: 16000
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
            frameCount: 16000
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
            frameCount: 16000
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
            frameCount: 16000
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
            rmsPowerDB: -55,
            peakPowerDB: -42,
            audibleDuration: 0.08,
            audibleFrameRatio: 0.04,
            frameCount: 16000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testRMSJustBelowThresholdFallsThroughToPeakCheck() {
        let analysis = AudioContentAnalysis(
            duration: 1.0,
            rmsPowerDB: -48.01,
            peakPowerDB: -43,
            audibleDuration: 0.1,
            audibleFrameRatio: 0.05,
            frameCount: 16000
        )
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    func testIsAudibleForQuietButLegitimateSpeech() {
        let analysis = AudioContentAnalysis(
            duration: 2.0,
            rmsPowerDB: -45,
            peakPowerDB: -38,
            audibleDuration: 0.5,
            audibleFrameRatio: 0.1,
            frameCount: 32000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }

    func testIsAudibleForPreviouslyRejectedModerateSignal() {
        let analysis = AudioContentAnalysis(
            duration: 1.5,
            rmsPowerDB: -44,
            peakPowerDB: -36,
            audibleDuration: 0.3,
            audibleFrameRatio: 0.08,
            frameCount: 24000
        )
        XCTAssertTrue(analysis.containsAudibleSignal)
    }
}
