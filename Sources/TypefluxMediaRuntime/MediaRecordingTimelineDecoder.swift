import AVFoundation
import TypefluxMediaProtocol

/// Read-only, batch timeline extraction. No playback or capture devices.
public enum MediaRecordingTimelineDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) async throws -> MediaResponse {
        try request.validate()
        guard request.operation == .recordingTimeline else { throw MediaFailure.invalidProtocol }
        let input = directory.appendingPathComponent("input")
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= MediaRecordingTimeline.inputBytes else { throw MediaFailure.tooLarge }
        let hinted = directory.appendingPathComponent("timeline.mov")
        try FileManager.default.linkItem(at: input, to: hinted)
        defer { try? FileManager.default.removeItem(at: hinted) }
        let asset = AVURLAsset(url: hinted, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        return try await withTaskCancellationHandler {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaFailure.unreadable }
            let size = try await track.load(.naturalSize)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= 8192, size.height <= 8192, size.width * size.height <= 16_777_216 else { throw MediaFailure.tooLarge }
            let transformed = CGRect(origin: .zero, size: size).applying(try await track.load(.preferredTransform)).size
            let fps = try await track.load(.nominalFrameRate)
            // Validate metadata before native frame allocation; placeholders are never returned.
            var result = MediaRecordingTimeline(duration: duration, width: abs(transformed.width), height: abs(transformed.height),
                fps: fps, rasters: Array(repeating: .init(width: 1, height: 1), count: 10), audio: .unavailable)
            try result.validate()
            result.rasters = []
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 120)
            defer { generator.cancelAllCGImageGeneration() }
            for index in 0..<10 {
                try Task.checkCancellation()
                let image = try generator.copyCGImage(at: CMTime(seconds: duration * Double(index) / 10, preferredTimescale: 600), actualTime: nil)
                guard image.width <= 200, image.height <= 120 else { throw MediaFailure.tooLarge }
                result.rasters.append(try MediaPreviewDecoder.write(image, index: index, page: nil, directory: directory))
            }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard tracks.count <= 8 else { throw MediaFailure.tooLarge }
                if tracks.isEmpty { result.audio = .absent }
                else {
                    result.waveform = try waveform(asset, tracks: tracks, duration: duration)
                    result.audio = .available
                }
            } catch {
                try Task.checkCancellation()
                // A partial scan is never presented as the whole recording or as silence.
                result.waveform = []; result.audio = .unavailable
            }
            try Task.checkCancellation()
            var response = MediaResponse(id: request.id); response.timeline = result
            try response.validate(for: request)
            return response
        } onCancel: { asset.cancelLoading() }
    }

    private static func waveform(_ asset: AVAsset, tracks: [AVAssetTrack], duration: Double) throws -> [Float] {
        var accumulator = MediaRecordingPeaks(duration: duration)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaFailure.unreadable }
            reader.add(output)
            guard reader.startReading() else { throw MediaFailure.unreadable }
            defer { reader.cancelReading() }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline,
                      let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaFailure.unavailable }
                let length = CMBlockBufferGetDataLength(block)
                try accumulator.admit(bytes: length)
                var values = [Float](repeating: 0, count: length / 4)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw MediaFailure.unreadable }
                try accumulator.append(values, time: sample.presentationTimeStamp.seconds)
            }
            guard reader.status == .completed else { throw MediaFailure.unreadable }
        }
        return accumulator.peaks
    }
}

/// Same absolute peak/buffer timestamp semantics as the recording meter, across all tracks.
public struct MediaRecordingPeaks {
    public private(set) var peaks = [Float](repeating: 0, count: 160)
    private let duration: Double
    private var bytes = 0
    public init(duration: Double) { self.duration = duration }
    public mutating func admit(bytes: Int) throws {
        guard bytes > 0, bytes <= 4 * 1024 * 1024, bytes % 4 == 0,
              self.bytes <= MediaRecordingTimeline.pcmBytes - bytes else { throw MediaFailure.tooLarge }
        self.bytes += bytes
    }
    public mutating func append(_ values: [Float], time: Double) throws {
        guard duration.isFinite, duration > 0, duration <= 86_400, time.isFinite,
              time >= 0, time <= duration, values.count <= 1024 * 1024 else { throw MediaFailure.unreadable }
        let bin = min(159, Int(time / duration * 160))
        let peak = values.reduce(Float(0)) { max($0, $1.isFinite ? min(1, abs($1)) : 0) }
        peaks[bin] = max(peaks[bin], peak)
    }
}
