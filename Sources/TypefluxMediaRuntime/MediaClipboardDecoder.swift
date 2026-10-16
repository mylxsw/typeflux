import AVFoundation
import PDFKit
import TypefluxMediaProtocol

/// File-only metadata and peaks. No microphone, playback, clipboard or app DI.
public enum MediaClipboardDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) async throws -> MediaResponse {
        try request.validate()
        guard request.operation == .clipboardMedia, let options = request.clipboard else { throw MediaFailure.invalidProtocol }
        try Task.checkCancellation()
        let input = directory.appendingPathComponent("input")
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        let limit = options.kind == .pdf ? MediaLimits.inputBytes : MediaAVLimits.inputBytes
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= limit else { throw MediaFailure.tooLarge }
        let value: MediaClipboardResult
        if options.kind == .pdf {
            guard let document = PDFDocument(url: input), !document.isLocked else { throw MediaFailure.unreadable }
            value = .init(pages: document.pageCount)
        } else {
            let hinted = directory.appendingPathComponent("decode." + (options.container ?? .wav).rawValue)
            try FileManager.default.linkItem(at: input, to: hinted)
            defer { try? FileManager.default.removeItem(at: hinted) }
            let asset = AVURLAsset(url: hinted)
            value = try await withTaskCancellationHandler {
                let seconds = try await asset.load(.duration).seconds
                let metadata = MediaClipboardResult(duration: seconds)
                try metadata.validate(for: .init(kind: .duration))
                if options.kind == .duration { return metadata }
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaFailure.unreadable }
                return .init(duration: seconds, waveform: try peaks(asset, track: track, seconds: seconds))
            } onCancel: { asset.cancelLoading() }
        }
        try Task.checkCancellation()
        var response = MediaResponse(id: request.id); response.clipboard = value
        try response.validate(for: request)
        return response
    }

    private static func peaks(_ asset: AVAsset, track: AVAssetTrack, seconds: Double) throws -> [Float] {
        let window = min(seconds, MediaClipboardOptions.scanSeconds)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: window, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: MediaClipboardOptions.sampleRate
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaFailure.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw MediaFailure.unreadable }
        defer { reader.cancelReading() }
        var accumulator = MediaClipboardWaveformAccumulator(bars: MediaClipboardOptions.buckets,
            expectedSamples: Int(window * MediaClipboardOptions.sampleRate))
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            try accumulator.admit(bytes: length)
            guard length > 0 else { continue }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw MediaFailure.unreadable }
            accumulator.add(samples)
        }
        guard reader.status == .completed else { throw MediaFailure.unreadable }
        return accumulator.levels()
    }
}

/// Fixed upper bounds apply before buffer allocation and sample-index arithmetic.
public struct MediaClipboardWaveformAccumulator {
    public private(set) var peaks: [Float]
    private let expectedSamples: Int
    private var count = 0
    private var bytes = 0
    public init(bars: Int, expectedSamples: Int) {
        peaks = Array(repeating: 0, count: min(MediaClipboardOptions.buckets, max(bars, 1)))
        self.expectedSamples = min(4_800_000, max(expectedSamples, 1))
    }
    public mutating func admit(bytes: Int) throws {
        guard bytes >= 0, bytes <= MediaAVLimits.chunkBytes, bytes % 4 == 0,
              self.bytes <= MediaClipboardOptions.pcmBytes - bytes else { throw MediaFailure.tooLarge }
        self.bytes += bytes
    }
    public mutating func add(_ samples: [Float]) {
        for sample in samples {
            let index = min(count * peaks.count / expectedSamples, peaks.count - 1)
            peaks[index] = max(peaks[index], sample.isFinite ? abs(sample) : 0)
            count = min(count + 1, MediaClipboardOptions.pcmBytes / 4)
        }
    }
    public func levels() -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { min($0 / loudest, 1) }
    }
}
