import AppKit
import Darwin
import TypefluxMediaProtocol

/// Compatibility facade: only validated RGBA pixels enter the UI process.
enum AskFilePreviewPDF {
    struct Result: @unchecked Sendable {
        var images: [CGImage]
        var numbers: [Int]
        var pages: Int
        var duration: Double = 0
        var start: Double = 0
        var waveform: [Float] = []
    }
    static func render(_ url: URL, pixels: CGSize, evidence: AskFileHit.Evidence?,
                       cancellation: AskSearchCancellation, worker: MediaWorker = .previews) throws -> Result {
        try MediaPreviewDisplay.render(url, pixels: pixels, pdf: true, evidence: evidence,
                                       cancellation: cancellation, worker: worker)
    }
    static func ranges(in text: String, passage: String) -> [NSRange] {
        MediaPreviewText.ranges(in: text, passage: passage)
    }
}

enum MediaPreviewDisplay {
    /// Runs on an owned background task; original bytes never enter a host decoder.
    static func render(_ url: URL, pixels: CGSize, pdf: Bool, evidence: AskFileHit.Evidence?,
                       cancellation: AskSearchCancellation, worker: MediaWorker = .previews) throws -> AskFilePreviewPDF.Result {
        try renderRequest(url, pixels: pixels, operation: pdf ? .previewPDF : .previewImage,
                          evidence: evidence, start: 0, cancellation: cancellation, worker: worker)
    }

    static func renderAV(_ url: URL, pixels: CGSize, video: Bool, start: Double,
                         cancellation: AskSearchCancellation, worker: MediaWorker = .previews) throws -> AskFilePreviewPDF.Result {
        try renderRequest(url, pixels: pixels, operation: video ? .previewVideo : .previewAudio,
                          evidence: nil, start: start, cancellation: cancellation, worker: worker)
    }

    private static func renderRequest(_ url: URL, pixels: CGSize, operation: MediaRequest.Operation,
                                      evidence: AskFileHit.Evidence?, start: Double,
                                      cancellation: AskSearchCancellation, worker: MediaWorker) throws -> AskFilePreviewPDF.Result {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 1, pixels.height >= 1,
              pixels.width <= Double(MediaPreviewOptions.maxEdge), pixels.height <= Double(MediaPreviewOptions.maxEdge)
        else { throw MediaFailure.tooLarge }
        let options = MediaPreviewOptions(width: Int(pixels.width), height: Int(pixels.height),
                                          page: operation == .previewPDF ? evidence?.page : nil,
                                          passage: operation == .previewPDF ? evidence?.text : nil,
                                          start: operation.isAV ? (start.isFinite ? max(0, start) : 0) : nil,
                                          container: operation.isAV ? MediaAVContainer(rawValue: url.pathExtension.lowercased()) : nil)
        return try decode(.file(url), operation: operation, options: options, cancellation: cancellation, worker: worker)
    }

    static func renderImage(_ data: Data, type: MediaImageType?, cancellation: AskSearchCancellation,
                            worker: MediaWorker = .previews, edge: Int = 1600) throws -> AskFilePreviewPDF.Result {
        guard (1...1600).contains(edge) else { throw MediaFailure.tooLarge }
        let options = MediaPreviewOptions(width: edge, height: edge, imageType: type)
        return try decode(.data(data), operation: .previewImage, options: options, cancellation: cancellation, worker: worker)
    }

    static func renderIcon(_ icon: MediaNativeIcon, edge: Int, cancellation: AskSearchCancellation,
                           worker: MediaWorker = .previews) throws -> AskFilePreviewPDF.Result {
        try decode(.data(Data()), operation: .nativeIcon, options: .init(width: edge, height: edge),
                   cancellation: cancellation, worker: worker, icon: icon)
    }

    static func renderQuickLook(_ target: MediaQuickLook, options: MediaPreviewOptions, cancellation: AskSearchCancellation,
                                worker: MediaWorker = .previews) throws -> AskFilePreviewPDF.Result {
        try decode(.data(Data()), operation: .quickLook, options: options, cancellation: cancellation, worker: worker, quickLook: target)
    }

    private static func decode(_ input: MediaWorker.Input, operation: MediaRequest.Operation, options: MediaPreviewOptions,
                               cancellation: AskSearchCancellation, worker: MediaWorker, icon: MediaNativeIcon? = nil, quickLook: MediaQuickLook? = nil) throws -> AskFilePreviewPDF.Result {
        return try worker.perform(operation, input: input, preview: options, icon: icon, quickLook: quickLook,
                                  isCancelled: { cancellation.isCancelled }) { response, directory in
            guard let result = response.preview else { throw MediaFailure.invalidProtocol }
            let images = try result.rasters.enumerated().map { index, raster in
                if cancellation.isCancelled { throw CancellationError() }
                let bytes = try read(raster, index: index, directory: directory)
                // This is a fixed RGBA bitmap constructor, not an image-format parser.
                guard let provider = CGDataProvider(data: bytes as CFData),
                      let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: raster.stride, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                            CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw MediaFailure.unavailable }
                return image
            }
            return .init(images: images, numbers: result.rasters.compactMap(\.page), pages: result.pages,
                         duration: result.duration ?? 0, start: result.start ?? 0, waveform: result.waveform ?? [])
        }
    }

    static func read(_ raster: MediaRaster, index: Int, directory: Int32) throws -> Data {
        let fd = openat(directory, MediaRaster.filename(index), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MediaFailure.invalidProtocol }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == raster.bytes else { throw MediaFailure.invalidProtocol }
        // The child promised this exact raw output; an unreadable payload is a protocol failure.
        guard let bytes = try? handle.read(upToCount: raster.bytes + 1), bytes.count == raster.bytes else { throw MediaFailure.invalidProtocol }
        return bytes
    }
}
