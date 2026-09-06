import AVFoundation
import Foundation

/// Tracks a digital-zero prefix separately from ordinary quiet audio. This is
/// diagnostic evidence of signal arrival, not VAD and not a reason to drop samples.
struct AudioInputSignalTracker {
    private(set) var firstSignalAt: Date?
    private(set) var leadingZeroDuration: TimeInterval = 0

    mutating func observe(_ buffer: AVAudioPCMBuffer, receivedAt: Date) {
        guard firstSignalAt == nil, buffer.format.sampleRate > 0 else { return }
        if let frame = Self.firstNonzeroFrame(in: buffer) {
            leadingZeroDuration += Double(frame) / buffer.format.sampleRate
            firstSignalAt = receivedAt
        } else {
            leadingZeroDuration += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    static func firstNonzeroFrame(in buffer: AVAudioPCMBuffer) -> Int? {
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                let plane = interleaved ? 0 : channel
                let index = interleaved ? frame * channels + channel : frame
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    value = Double(buffer.floatChannelData?[plane][index] ?? 0)
                case .pcmFormatFloat64:
                    let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    value = buffers[plane].mData?.assumingMemoryBound(to: Double.self)[index] ?? 0
                case .pcmFormatInt16:
                    value = Double(buffer.int16ChannelData?[plane][index] ?? 0)
                case .pcmFormatInt32:
                    value = Double(buffer.int32ChannelData?[plane][index] ?? 0)
                default:
                    continue
                }
                if value.isFinite, value != 0 { return frame }
            }
        }
        return nil
    }
}
