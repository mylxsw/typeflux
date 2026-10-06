import AVFoundation
import Foundation

enum AudioPCMBufferSnapshot {
    /// Call on the producer's queue before handing audio to an asynchronous consumer.
    /// Channel-data getters lazily initialize shared pointer storage, so even two
    /// readers can race on a fresh AVAudioPCMBuffer. Copy the read-only buffer list
    /// instead, and initialize the snapshot's channel pointers before publishing it.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
