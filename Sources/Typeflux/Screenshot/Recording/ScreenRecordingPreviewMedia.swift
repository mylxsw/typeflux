import AppKit
import AVFoundation
import ImageIO

struct ScreenRecordingPreviewMedia: @unchecked Sendable {
    var thumbnails: [CGImage] = []
    var waveform: [Float] = []
    var size: CGSize = .zero
    var fps: Float = 0
    var fileBytes: Int64 = 0

    static func thumbnail(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "gif", let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 120)
        defer { generator.cancelAllCGImageGeneration() }
        return try generator.copyCGImage(at: .zero, actualTime: nil)
    }

    static func load(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ScreenRecordingFailure.noFrames }
        var result = Self()
        result.fileBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: size).applying(transform).size
            result.size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            result.fps = try await track.load(.nominalFrameRate)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 120)
        defer { generator.cancelAllCGImageGeneration() }
        for index in 0 ..< 10 {
            try Task.checkCancellation()
            let time = CMTime(seconds: duration * Double(index) / 10, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                result.thumbnails.append(image)
            }
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if !tracks.isEmpty {
            result.waveform = [Float](repeating: 0, count: 160)
            for track in tracks {
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { continue }
                reader.add(output)
                guard reader.startReading() else { continue }
                defer { reader.cancelReading() }
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let position = sample.presentationTimeStamp.seconds
                    let bin = min(159, max(0, Int(position / duration * 160)))
                    result.waveform[bin] = max(result.waveform[bin], ScreenRecordingAudioMeter.amplitude(sample))
                }
            }
        }
        return result
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
