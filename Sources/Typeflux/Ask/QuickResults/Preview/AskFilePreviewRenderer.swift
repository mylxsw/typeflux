import AppKit
import AVFoundation
import ImageIO
import PDFKit
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
        if kind == .image {
            // Avoid Quick Look's service round trip for ImageIO formats. SVG and other unsupported
            // formats still use Quick Look below. Decode at the displayed pixel size off the UI actor.
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let image = Self.image(hit.url, pixels: pixels, info: info)
                try Task.checkCancellation()
                return RasterImage(image: image)
            }
            let raster = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            if let image = raster.image {
                return AskFilePreviewContent(kind: kind, images: [NSImage(cgImage: image, size: .zero)])
            }
        }
        if kind == .pdf {
            let cancellation = AskSearchCancellation()
            let rendered = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) { try pdf(
                    hit.url,
                    pixels: pixels,
                    cancellation: cancellation
                ) }.value
            } onCancel: { cancellation.cancel() }
            return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                         pageCount: rendered.pages)
        }
        if kind == .video || kind == .audio {
            return try await media(hit.url, kind: kind, pixels: pixels)
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

    private struct RasterImage: @unchecked Sendable { var image: CGImage? }

    private nonisolated static func image(_ url: URL, pixels: CGSize, info: AskFileReadResponse) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var maximum = max(pixels.width, pixels.height)
        if let width = info.imageWidth, let height = info.imageHeight, width > 0, height > 0 {
            maximum = ceil(CGFloat(max(width, height)) * min(
                1,
                min(pixels.width / CGFloat(width), pixels.height / CGFloat(height))
            ))
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maximum))
        ] as CFDictionary)
    }

    private struct PDFImages: @unchecked Sendable { var images: [CGImage]; var pages: Int }

    private nonisolated static func pdf(_ url: URL, pixels: CGSize,
                                        cancellation: AskSearchCancellation) throws -> PDFImages {
        guard !cancellation.isCancelled, let document = PDFDocument(url: url), !document.isLocked,
              document.pageCount > 0 else {
            throw AskFileReadError.unavailable
        }
        var images: [CGImage] = []
        for index in 0 ..< min(3, document.pageCount) {
            guard !cancellation.isCancelled,
                  let page = document.page(at: index) else { throw AskFileReadError.cancelled }
            let thumbnail = page.thumbnail(of: pixels, for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw AskFileReadError.unavailable }
            images.append(image)
        }
        return PDFImages(images: images, pages: document.pageCount)
    }

    private static func media(_ url: URL, kind: AskFilePreviewKind,
                              pixels: CGSize) async throws -> AskFilePreviewContent {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try await mediaContent(asset, kind: kind, pixels: pixels)
        } onCancel: { asset.cancelLoading() }
    }

    private static func mediaContent(_ asset: AVAsset, kind: AskFilePreviewKind,
                                     pixels: CGSize) async throws -> AskFilePreviewContent {
        try Task.checkCancellation()
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0 else { throw AskFileReadError.unavailable }
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = pixels
            return try await withTaskCancellationHandler {
                let frame = try await generator.image(at: .zero).image
                try Task.checkCancellation()
                return AskFilePreviewContent(
                    kind: kind,
                    images: [NSImage(cgImage: frame, size: .zero)],
                    duration: duration
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
                duration: duration,
                cancellation: cancellation
            ) }.value
        } onCancel: { cancellation.cancel(); asset.cancelLoading() }
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, duration: duration, waveform: samples)
    }

    private nonisolated static func waveform(_ asset: AVAsset, track: AVAssetTrack, duration: Double,
                                             cancellation: AskSearchCancellation) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: min(30, duration), preferredTimescale: 600)
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
            let index = max(0, min(79, Int(time / max(0.001, min(30, duration)) * 80)))
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
