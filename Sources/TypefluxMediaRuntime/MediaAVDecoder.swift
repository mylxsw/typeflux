import AVFoundation
import Foundation
import TypefluxMediaProtocol

/// File-only decoding. No capture devices, playback, app DI or permission UI.
public enum MediaAVDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) async throws -> MediaResponse {
        try request.validate()
        guard request.operation.isAV, let options = request.preview else { throw MediaFailure.invalidProtocol }
        let url = directory.appendingPathComponent("input")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= MediaAVLimits.inputBytes
        else { throw MediaFailure.tooLarge }
        // AVFoundation needs a format hint for extensionless private copies.
        // The enum prevents path injection; a hard link adds no second media copy.
        let container = options.container ?? (request.operation == .previewVideo ? .mov : .wav)
        let hinted = directory.appendingPathComponent("decode." + container.rawValue)
        try FileManager.default.linkItem(at: url, to: hinted)
        defer { try? FileManager.default.removeItem(at: hinted) }
        let asset = AVURLAsset(url: hinted)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 0, duration <= MediaAVLimits.maximumDuration
            else { throw MediaFailure.unreadable }
            let start = MediaAVLimits.start(options.start ?? 0, duration: duration)
            var preview = MediaPreviewResult(rasters: [])
            preview.duration = duration; preview.start = start
            if request.operation == .previewVideo {
                guard let track = try await asset.loadTracks(withMediaType: .video).first
                else { throw MediaFailure.unreadable }
                let size = try await track.load(.naturalSize)
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width <= 100_000, size.height <= 100_000,
                      size.width * size.height <= 100_000_000 else { throw MediaFailure.tooLarge }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: options.width, height: options.height)
                let raster = try await withTaskCancellationHandler {
                    let frame = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image
                    try Task.checkCancellation()
                    return try MediaPreviewDecoder.write(frame, index: 0, page: nil, directory: directory)
                } onCancel: { generator.cancelAllCGImageGeneration() }
                preview.rasters = [raster]
            } else {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first
                else { throw MediaFailure.unreadable }
                preview.waveform = try waveform(asset, track: track, duration: duration, start: start)
            }
            try Task.checkCancellation()
            var response = MediaResponse(id: request.id); response.preview = preview
            try response.validate(for: request)
            return response
        } onCancel: { asset.cancelLoading() }
    }

    private static func waveform(_ asset: AVAsset, track: AVAssetTrack, duration: Double, start: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let window = min(30, duration - start)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: window, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw MediaFailure.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw MediaFailure.unreadable }
        defer { reader.cancelReading() }
        var accumulator = MediaWaveformAccumulator(start: start, window: window)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(buffer)
            try accumulator.admit(bytes: count)
            guard count > 0 else { continue }
            var values = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw MediaFailure.unreadable }
            try accumulator.append(values, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard reader.status == .completed else { throw MediaFailure.unreadable }
        return accumulator.normalized
    }
}

/// Counts bytes before native-buffer allocation and bounds timestamps before Int conversion.
public struct MediaWaveformAccumulator {
    private let start: Double
    private let window: Double
    private var total = 0
    private var peaks = [Float](repeating: 0, count: 80)
    public init(start: Double, window: Double) { self.start = start; self.window = window }
    public mutating func admit(bytes: Int) throws {
        guard bytes >= 0, bytes <= MediaAVLimits.chunkBytes, bytes % 4 == 0,
              total <= MediaAVLimits.decodedBytes - bytes else { throw MediaFailure.tooLarge }
        total += bytes
    }
    public mutating func append(_ values: [Float], time: Double) throws {
        guard time.isFinite, start.isFinite, window.isFinite, window >= 0 else { throw MediaFailure.unreadable }
        // Decoder preroll is permitted; samples outside the requested window are not displayed.
        guard time >= start, time < start + window else { return }
        let bucket = min(79, max(0, (time - start) / max(0.001, window) * 80))
        let index = Int(bucket)
        peaks[index] = max(peaks[index], values.reduce(Float(0)) { max($0, abs($1.isFinite ? $1 : 0)) })
    }
    public var normalized: [Float] {
        let maximum = max(0.001, peaks.max() ?? 0)
        return peaks.map { $0 / maximum }
    }
}
