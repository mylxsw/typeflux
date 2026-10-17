import AVFoundation
import Foundation

enum AudioPCMBufferSnapshot {
    /// Call on the producer's queue before handing audio to an asynchronous consumer.
    /// Channel-data getters lazily initialize shared pointer storage, so even two
    /// readers can race on a fresh AVAudioPCMBuffer. Copy the read-only buffer list
    /// instead, and initialize the snapshot's channel pointers before publishing it.
    static func byteCount(_ buffer: AVAudioPCMBuffer, maximumBytes: Int) -> Int? {
        guard buffer.frameLength > 0, buffer.frameLength <= buffer.frameCapacity, maximumBytes > 0 else { return nil }
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let frameBytes = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        guard planes > 0, sources.count == planes, frameBytes > 0,
              frameBytes <= maximumBytes / planes,
              Int(buffer.frameLength) <= maximumBytes / (frameBytes * planes) else { return nil }
        let planeBytes = Int(buffer.frameLength) * frameBytes
        var total = 0
        for source in sources {
            let bytes = Int(source.mDataByteSize)
            guard source.mData != nil, bytes >= planeBytes, bytes <= maximumBytes - total else { return nil }
            total += bytes
        }
        return total
    }

    static func copy(_ buffer: AVAudioPCMBuffer, maximumBytes: Int? = nil) -> AVAudioPCMBuffer? {
        if let maximumBytes, byteCount(buffer, maximumBytes: maximumBytes) == nil { return nil }
        guard buffer.frameLength > 0,
              buffer.frameLength <= buffer.frameCapacity,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength

        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sources.count == destinations.count else { return nil }
        for (source, destination) in zip(sources, destinations) {
            guard let sourceData = source.mData,
                  let destinationData = destination.mData,
                  destination.mDataByteSize > 0,
                  source.mDataByteSize >= destination.mDataByteSize
            else { return nil }
            memcpy(destinationData, sourceData, Int(destination.mDataByteSize))
        }

        switch copy.format.commonFormat {
        case .pcmFormatFloat32:
            _ = copy.floatChannelData
        case .pcmFormatInt16:
            _ = copy.int16ChannelData
        case .pcmFormatInt32:
            _ = copy.int32ChannelData
        default:
            break
        }
        return copy
    }
}
