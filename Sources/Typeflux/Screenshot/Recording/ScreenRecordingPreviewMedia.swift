import AppKit
import AVFoundation
import TypefluxMediaProtocol

struct ScreenRecordingPreviewMedia: @unchecked Sendable {
    var thumbnails: [CGImage] = []
    var waveform: [Float] = []
    /// One waveform per source audio track, in file order.
    var tracks: [[Float]] = []
    var size: CGSize = .zero
    var fps: Float = 0
    var fileBytes: Int64 = 0
    var audio: MediaRecordingTimeline.Audio? = nil

    var audioNoticeKey: String {
        switch audio {
        case nil: "recording.timelineLoading"
        case .absent: "recording.noAudioTrack"
        case .available, .unavailable: "recording.timelineUnavailable"
        }
    }

    static func thumbnail(_ url: URL) async throws -> CGImage {
        try await ScreenRecordingTimelineLoader.shared.thumbnail(url)
    }

    static func load(_ url: URL, loader: ScreenRecordingTimelineLoader = .shared) async throws -> Self {
        try await loader.load(url)
    }

}

/// Read only a bounded PCM buffer. The lock protects delegate updates from UI polling.
final class ScreenRecordingAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    var level: Float {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func update(_ sample: CMSampleBuffer) {
        let next = Self.amplitude(sample)
        lock.lock(); value = next; lock.unlock()
    }

    static func amplitude(_ sample: CMSampleBuffer) -> Float {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= 4 * 1024 * 1024 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) ==
            kCMBlockBufferNoErr else { return 0 }
        var peak: Float = 0
        bytes.withUnsafeBytes { buffer in
            if format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                for index in stride(from: 0, to: length - 3, by: 4) {
                    let sample = buffer.loadUnaligned(fromByteOffset: index, as: Float.self)
                    if sample.isFinite {
                        peak = max(peak, abs(sample))
                    }
                }
            } else if format.mBitsPerChannel == 16 {
                for index in stride(from: 0, to: length - 1, by: 2) {
                    peak = max(peak, abs(Float(buffer.loadUnaligned(fromByteOffset: index, as: Int16.self))) / 32768)
                }
            }
        }
        return min(1, max(0, peak))
    }
}
