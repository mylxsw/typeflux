import AVFoundation
import Foundation

struct AudioContentAnalysis {
    private static let minimumAudibleDuration: TimeInterval = 0.08
    private static let minimumAudibleFrameRatio = 0.04

    let duration: TimeInterval
    let rmsPowerDB: Float
    let peakPowerDB: Float
    let audibleDuration: TimeInterval
    let audibleFrameRatio: Double
    let frameCount: AVAudioFramePosition

    var containsAudibleSignal: Bool {
        guard duration > 0 else { return false }

        if rmsPowerDB >= -42 {
            return true
        }

        return peakPowerDB >= -35
            && audibleDuration >= Self.minimumAudibleDuration
            && audibleFrameRatio >= Self.minimumAudibleFrameRatio
    }
}

enum AudioContentAnalyzer {
    static func analyze(fileURL: URL) throws -> AudioContentAnalysis {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = audioFile.length

        guard sampleRate > 0, totalFrames > 0 else {
            return AudioContentAnalysis(
                duration: 0,
                rmsPowerDB: -Float.infinity,
                peakPowerDB: -Float.infinity,
                audibleDuration: 0,
                audibleFrameRatio: 0,
                frameCount: totalFrames
            )
        }

        let chunkCapacity = AVAudioFrameCount(min(totalFrames, 8_192))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            throw NSError(
                domain: "AudioContentAnalyzer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio analysis buffer."]
            )
        }

        var frameCount: AVAudioFramePosition = 0
        var sumOfSquares = 0.0
        var peakAmplitude = 0.0
        var audibleFrameCount: AVAudioFramePosition = 0

        while audioFile.framePosition < totalFrames {
            try audioFile.read(into: buffer, frameCount: min(chunkCapacity, AVAudioFrameCount(totalFrames - audioFile.framePosition)))
            let framesInBuffer = Int(buffer.frameLength)
            guard framesInBuffer > 0, let channels = buffer.floatChannelData else { break }

            let channelCount = Int(buffer.format.channelCount)
            for frameIndex in 0..<framesInBuffer {
                var mixedSample = 0.0
                for channelIndex in 0..<channelCount {
                    mixedSample += Double(channels[channelIndex][frameIndex])
                }
                let sample = mixedSample / Double(channelCount)
                sumOfSquares += sample * sample
                peakAmplitude = max(peakAmplitude, abs(sample))
                if abs(sample) >= 0.01 {
                    audibleFrameCount += 1
                }
            }

            frameCount += AVAudioFramePosition(framesInBuffer)
        }

        let duration = Double(frameCount) / sampleRate
        let rms = frameCount > 0 ? sqrt(sumOfSquares / Double(frameCount)) : 0

        return AudioContentAnalysis(
            duration: duration,
            rmsPowerDB: decibels(fromAmplitude: rms),
            peakPowerDB: decibels(fromAmplitude: peakAmplitude),
            audibleDuration: Double(audibleFrameCount) / sampleRate,
            audibleFrameRatio: frameCount > 0 ? Double(audibleFrameCount) / Double(frameCount) : 0,
            frameCount: frameCount
        )
    }

    private static func decibels(fromAmplitude amplitude: Double) -> Float {
        guard amplitude > 0 else { return -Float.infinity }
        return Float(20 * log10(amplitude))
    }
}
