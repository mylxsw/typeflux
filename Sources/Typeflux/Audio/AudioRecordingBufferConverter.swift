import AVFoundation
import Foundation

final class AudioRecordingBufferConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        guard buffer.format.sampleRate > 0 else {
            throw NSError(
                domain: "AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Input audio has an invalid sample rate."]
            )
        }

        let converter = try converter(for: buffer.format)
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate converted audio buffer."]
            )
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }
        guard status != .error else {
            throw NSError(
                domain: "AudioRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to convert input audio."]
            )
        }

        return outputBuffer
    }

    private func converter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, sourceFormat == inputFormat {
            return converter
        }

        guard let nextConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create an input audio converter."]
            )
        }
        converter = nextConverter
        sourceFormat = inputFormat
        return nextConverter
    }
}
