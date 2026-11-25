import AVFoundation
import Foundation

/// Bounded rolling pre-roll window for Instant Voice Input on Core Audio capture.
struct CoreAudioPreRollBuffer {
    static let defaultDuration: TimeInterval = 0.5
    static let maximumPackets = 512

    let maximumDuration: TimeInterval
    private(set) var packets: [CoreAudioInputPacket] = []
    private(set) var bufferedFrames: AVAudioFramePosition = 0
    private var sampleRate: Double

    init(maximumDuration: TimeInterval = CoreAudioPreRollBuffer.defaultDuration, sampleRate: Double) {
        self.maximumDuration = max(0, maximumDuration)
        self.sampleRate = sampleRate
    }

    var bufferedDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(bufferedFrames) / sampleRate
    }

    mutating func append(_ packet: CoreAudioInputPacket) {
        let frames = AVAudioFramePosition(packet.buffer.frameLength)
        let packetRate = packet.buffer.format.sampleRate
        if packetRate > 0, packetRate != sampleRate {
            clear()
            sampleRate = packetRate
        }
        guard frames > 0, sampleRate > 0, maximumDuration > 0 else { return }
        let maxFrames = AVAudioFramePosition((maximumDuration * sampleRate).rounded())
        guard maxFrames > 0 else { return }

        while !packets.isEmpty,
              bufferedFrames + frames > maxFrames || packets.count >= Self.maximumPackets {
            let removed = packets.removeFirst()
            bufferedFrames = max(0, bufferedFrames - AVAudioFramePosition(removed.buffer.frameLength))
        }

        if frames > maxFrames {
            guard let tail = Self.tailPacket(from: packet, keepingFrames: AVAudioFrameCount(maxFrames)) else {
                return
            }
            packets.append(tail)
            bufferedFrames = AVAudioFramePosition(tail.buffer.frameLength)
            return
        }

        packets.append(packet)
        bufferedFrames += frames
    }

    mutating func drain() -> [CoreAudioInputPacket] {
        defer {
            packets.removeAll(keepingCapacity: false)
            bufferedFrames = 0
        }
        return packets
    }

    mutating func clear() {
        packets.removeAll(keepingCapacity: false)
        bufferedFrames = 0
    }

    private static func tailPacket(
        from packet: CoreAudioInputPacket,
        keepingFrames: AVAudioFrameCount
    ) -> CoreAudioInputPacket? {
        let source = packet.buffer
        guard keepingFrames > 0, source.frameLength > keepingFrames,
              source.format.commonFormat == .pcmFormatFloat32,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: keepingFrames),
              let srcChannels = source.floatChannelData,
              let dstChannels = copy.floatChannelData
        else { return nil }

        let skippedFrames = Int(source.frameLength - keepingFrames)
        let channels = Int(source.format.channelCount)
        if source.format.isInterleaved {
            let offset = skippedFrames * channels
            let count = Int(keepingFrames) * channels
            dstChannels[0].update(from: srcChannels[0].advanced(by: offset), count: count)
        } else {
            for channel in 0 ..< channels {
                dstChannels[channel].update(
                    from: srcChannels[channel].advanced(by: skippedFrames),
                    count: Int(keepingFrames)
                )
            }
        }
        copy.frameLength = keepingFrames
        let skippedSeconds = source.format.sampleRate > 0 ? Double(skippedFrames) / source.format.sampleRate : 0
        let sampleHostTime = packet.sampleHostTime == 0
            ? 0
            : packet.sampleHostTime &+ AVAudioTime.hostTime(forSeconds: skippedSeconds)
        return CoreAudioInputPacket(
            buffer: copy,
            sampleHostTime: sampleHostTime,
            callbackHostTime: packet.callbackHostTime
        )
    }
}
