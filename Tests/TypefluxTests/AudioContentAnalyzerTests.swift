import AVFoundation
@testable import Typeflux
import XCTest

final class AudioContentAnalyzerTests: XCTestCase {
    func testAnalyzeDetectsAudibleSignal() throws {
        let url = try writeTestAudio(samples: sineWaveSamples(amplitude: 0.2, frameCount: 16000))
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try AudioContentAnalyzer.analyze(fileURL: url)

        XCTAssertEqual(analysis.frameCount, 16000)
        XCTAssertEqual(analysis.duration, 1.0, accuracy: 0.001)
        XCTAssertTrue(analysis.containsAudibleSignal)
        XCTAssertGreaterThan(analysis.peakPowerDB, -20)
        XCTAssertGreaterThan(analysis.rmsPowerDB, -25)
    }

    func testAnalyzeTreatsNearSilentAudioAsNoSpeechCandidate() throws {
        let url = try writeTestAudio(samples: Array(repeating: 0.000_01, count: 8000))
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try AudioContentAnalyzer.analyze(fileURL: url)

        XCTAssertEqual(analysis.duration, 0.5, accuracy: 0.001)
        XCTAssertFalse(analysis.containsAudibleSignal)
        XCTAssertLessThan(analysis.peakPowerDB, -90)
        XCTAssertLessThan(analysis.rmsPowerDB, -90)
    }

    func testAnalyzeRejectsSingleTransientSpike() throws {
        var samples = Array(repeating: Float(0), count: 16000)
        samples[800] = 0.8
        let url = try writeTestAudio(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try AudioContentAnalyzer.analyze(fileURL: url)

        XCTAssertFalse(analysis.containsAudibleSignal)
        XCTAssertLessThan(analysis.audibleDuration, 0.01)
        XCTAssertLessThan(analysis.audibleFrameRatio, 0.001)
        XCTAssertGreaterThan(analysis.peakPowerDB, -5)
    }

    func testAnalyzeReturnsZeroDurationForEmptyAudioFile() throws {
        let url = try writeTestAudio(samples: [])
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try AudioContentAnalyzer.analyze(fileURL: url)

        XCTAssertEqual(analysis.frameCount, 0)
        XCTAssertEqual(analysis.duration, 0)
        XCTAssertFalse(analysis.containsAudibleSignal)
    }

    private func writeTestAudio(samples: [Float], sampleRate: Double = 16000) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false,
        ) else {
            throw NSError(domain: "AudioContentAnalyzerTests", code: 1)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(samples.count, 1)),
        ) else {
            throw NSError(domain: "AudioContentAnalyzerTests", code: 2)
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData, !samples.isEmpty {
            channelData[0].update(from: samples, count: samples.count)
        }

        try audioFile.write(from: buffer)
        return url
    }

    private func sineWaveSamples(amplitude: Float, frameCount: Int) -> [Float] {
        let frequency = 440.0
        let sampleRate = 16000.0

        return (0 ..< frameCount).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }
}
