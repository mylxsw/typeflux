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

    /// Pure allocation bound, shared by reservation and conversion before native allocation.
    static func outputCapacity(frameLength: AVAudioFrameCount, inputRate: Double, outputRate: Double,
                               bytesPerFrame: Int) throws -> AVAudioFrameCount {
        let frames = Double(frameLength) * outputRate / inputRate
        guard frameLength > 0, inputRate.isFinite, inputRate > 0,
              outputRate.isFinite, outputRate > 0, frames.isFinite, frames > 0,
              bytesPerFrame > 0, bytesPerFrame <= AudioBufferWriteCoordinator.maximumBufferBytes / 2,
              frames + 256 <= Double(AudioBufferWriteCoordinator.maximumBufferBytes / (2 * bytesPerFrame))
        else { throw RecordingAudioQueueError.invalidBuffer }
        return AVAudioFrameCount(frames) + 256
    }

    func reservationBytes(for buffer: AVAudioPCMBuffer) throws -> Int {
        guard AudioPCMBufferSnapshot.byteCount(buffer, maximumBytes: AudioBufferWriteCoordinator.maximumBufferBytes) != nil
        else { throw RecordingAudioQueueError.invalidBuffer }
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame) * Int(targetFormat.channelCount)
        return Int(try Self.outputCapacity(frameLength: buffer.frameLength, inputRate: buffer.format.sampleRate,
                                          outputRate: targetFormat.sampleRate, bytesPerFrame: bytesPerFrame)) * bytesPerFrame * 2
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

        let outputCapacity = try Self.outputCapacity(
            frameLength: buffer.frameLength, inputRate: buffer.format.sampleRate,
            outputRate: targetFormat.sampleRate,
            bytesPerFrame: Int(targetFormat.streamDescription.pointee.mBytesPerFrame) * Int(targetFormat.channelCount)
        )
        let converter = try converter(for: buffer.format)
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
