import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Each reader belongs to one serial queue. Cancellation reaches its deadline-bound pipe loop.
private final class AskPreviewReader: @unchecked Sendable {
    let reader: any AskFileReading
    let queue = DispatchQueue(label: "typeflux.preview.reader", qos: .utility)
    init(_ reader: any AskFileReading) {
        self.reader = reader
    }

    func read(_ request: AskFileReadRequest) async throws -> AskFileReadResponse {
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result { try reader.read(
                        request,
                        isCancelled: { cancellation.isCancelled }
                    ) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

@MainActor
enum AskFilePreviewRenderer {
    private static let reader = AskPreviewReader(AskFileReader(timeout: 2, startupTimeout: 3))

    static func metadata(_ hit: AskFileHit, readText: Bool) async throws -> AskFileReadResponse {
        try await reader.read(.init(operation: .preview, path: hit.path, readText: readText))
    }

    static func generate(_ hit: AskFileHit, kind: AskFilePreviewKind, pixels: CGSize,
                         info: AskFileReadResponse) async throws -> AskFilePreviewContent {
        if kind.readsText {
            guard let text = info.text else { throw AskFileReadError.unavailable }
            return AskFilePreviewContent(kind: kind, text: text, truncated: info.truncated == true)
        }
        // SVG retains the existing system Quick Look service path below. Failed
        // bitmap/PDF decoding never falls back to parsing the original in the host.
        if kind == .pdf || (kind == .image && hit.url.pathExtension.lowercased() != "svg") {
            let cancellation = AskSearchCancellation()
            let rendered = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) { try MediaPreviewDisplay.render(
                    hit.url, pixels: pixels, pdf: kind == .pdf,
                    evidence: hit.evidence, cancellation: cancellation
                ) }.value
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                         pageCount: rendered.pages, pageNumbers: rendered.numbers)
        }
        if kind == .video || kind == .audio {
            return try await media(hit.url, kind: kind, pixels: pixels, start: hit.evidence?.time ?? 0)
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: hit.url,
            size: pixels,
            scale: 1,
            representationTypes: .thumbnail
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            try Task.checkCancellation()
            return AskFilePreviewContent(kind: kind, images: [representation.nsImage])
        } onCancel: { QLThumbnailGenerator.shared.cancel(request) }
    }

    private static func media(_ url: URL, kind: AskFilePreviewKind,
                              pixels: CGSize, start: TimeInterval) async throws -> AskFilePreviewContent {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try await mediaContent(asset, kind: kind, pixels: pixels, start: start)
        } onCancel: { asset.cancelLoading() }
    }

    private static func mediaContent(_ asset: AVAsset, kind: AskFilePreviewKind,
                                     pixels: CGSize, start requestedStart: TimeInterval) async throws -> AskFilePreviewContent {
        try Task.checkCancellation()
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0 else { throw AskFileReadError.unavailable }
        let start = requestedStart.isFinite ? max(0, min(max(0, duration - 0.001), requestedStart)) : 0
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = pixels
            return try await withTaskCancellationHandler {
                let frame = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image
                try Task.checkCancellation()
                return AskFilePreviewContent(
                    kind: kind,
                    images: [NSImage(cgImage: frame, size: .zero)],
                    duration: duration, startTime: start
                )
            } onCancel: { generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
        }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first
        else { throw AskFileReadError.unavailable }
        let cancellation = AskSearchCancellation()
        let samples = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try waveform(
                asset,
                track: track,
                duration: duration, start: start,
                cancellation: cancellation
            ) }.value
        } onCancel: { cancellation.cancel(); asset.cancelLoading() }
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, duration: duration, startTime: start, waveform: samples)
    }

    private nonisolated static func waveform(_ asset: AVAsset, track: AVAssetTrack, duration: Double,
                                             start: TimeInterval, cancellation: AskSearchCancellation) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: min(30, duration - start), preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw AskFileReadError.unavailable }
        reader.add(output)
        guard reader.startReading() else { throw AskFileReadError.unavailable }
        defer { reader.cancelReading() }
        var peaks = [Float](repeating: 0, count: 80)
        while !cancellation.isCancelled, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let index = max(0, min(79, Int((time - start) / max(0.001, min(30, duration - start)) * 80)))
            let length = CMBlockBufferGetDataLength(buffer)
            guard length >= MemoryLayout<Float>.size else { continue }
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            if status == kCMBlockBufferNoErr {
                peaks[index] = max(peaks[index], values.reduce(Float(0)) { max($0, abs($1.isFinite ? $1 : 0)) })
            }
        }
        guard !cancellation.isCancelled, reader.status != .failed else { throw AskFileReadError.unavailable }
        let maxPeak = max(0.001, peaks.max() ?? 0)
        return peaks.map { $0 / maxPeak }
    }
}
