import AVFoundation
@testable import Typeflux
import XCTest

final class LowEnergyAudioPreparerTests: XCTestCase {
    func testPrepareNormalizesQuietAudioAndAddsPadding() throws {
        let sourceURL = try writeAudio(
            samples: sineWave(amplitude: 0.003, frameCount: 48_000, sampleRate: 48_000),
            sampleRate: 48_000
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = AudioFile(fileURL: sourceURL, duration: 1)
        let analysis = try AudioContentAnalyzer.analyze(fileURL: sourceURL)

        let prepared = try LowEnergyAudioPreparer.prepare(audioFile: source, analysis: analysis)
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        let outputFile = try AVAudioFile(forReading: prepared.fileURL)
        XCTAssertEqual(outputFile.processingFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(outputFile.processingFormat.channelCount, 1)
        XCTAssertEqual(prepared.duration, 1.4, accuracy: 0.001)
        XCTAssertEqual(Double(outputFile.length) / outputFile.processingFormat.sampleRate, 1.4, accuracy: 0.02)

        let outputAnalysis = try AudioContentAnalyzer.analyze(fileURL: prepared.fileURL)
        XCTAssertGreaterThan(outputAnalysis.peakPowerDB, analysis.peakPowerDB + 15)
        XCTAssertLessThanOrEqual(outputAnalysis.peakPowerDB, -11.5)

        let samples = try readSamples(from: outputFile)
        XCTAssertTrue(samples.prefix(3_100).allSatisfy { abs($0) < 0.000_1 })
        XCTAssertTrue(samples.suffix(3_100).allSatisfy { abs($0) < 0.000_1 })
    }

    func testPrepareKeepsSilenceFinite() throws {
        let sourceURL = try writeAudio(samples: Array(repeating: 0, count: 8_000), sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = AudioFile(fileURL: sourceURL, duration: 0.5)
        let analysis = try AudioContentAnalyzer.analyze(fileURL: sourceURL)

        let prepared = try LowEnergyAudioPreparer.prepare(audioFile: source, analysis: analysis)
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        let outputFile = try AVAudioFile(forReading: prepared.fileURL)
        let samples = try readSamples(from: outputFile)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 == 0 })
    }

    private func writeAudio(samples: [Float], sampleRate: Double) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData?[0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
        return url
    }

    private func readSamples(from file: AVAudioFile) throws -> [Float] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func sineWave(amplitude: Float, frameCount: Int, sampleRate: Double) -> [Float] {
        (0 ..< frameCount).map { frame in
            amplitude * Float(sin(2 * .pi * 440 * Double(frame) / sampleRate))
        }
    }
}
