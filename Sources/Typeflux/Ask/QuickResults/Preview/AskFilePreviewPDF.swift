import AppKit
import Darwin
import TypefluxMediaProtocol

/// Compatibility facade: only validated RGBA pixels enter the UI process.
enum AskFilePreviewPDF {
    struct Result: @unchecked Sendable {
        var images: [CGImage]
        var numbers: [Int]
        var pages: Int
    }
    static func render(_ url: URL, pixels: CGSize, evidence: AskFileHit.Evidence?,
                       cancellation: AskSearchCancellation) throws -> Result {
        try MediaPreviewDisplay.render(url, pixels: pixels, pdf: true, evidence: evidence,
                                       cancellation: cancellation)
    }
    static func ranges(in text: String, passage: String) -> [NSRange] {
        MediaPreviewText.ranges(in: text, passage: passage)
    }
}

enum MediaPreviewDisplay {
    /// Runs on an owned background task; original bytes never enter a host decoder.
    static func render(_ url: URL, pixels: CGSize, pdf: Bool, evidence: AskFileHit.Evidence?,
                       cancellation: AskSearchCancellation, worker: MediaWorker = .previews) throws -> AskFilePreviewPDF.Result {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 1, pixels.height >= 1,
              pixels.width <= Double(MediaPreviewOptions.maxEdge), pixels.height <= Double(MediaPreviewOptions.maxEdge)
        else { throw MediaFailure.tooLarge }
        let options = MediaPreviewOptions(width: Int(pixels.width), height: Int(pixels.height),
                                          page: pdf ? evidence?.page : nil, passage: pdf ? evidence?.text : nil)
        return try worker.perform(pdf ? .previewPDF : .previewImage, input: .file(url), preview: options,
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
            return .init(images: images, numbers: result.rasters.compactMap(\.page), pages: result.pages)
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
        let bytes = try handle.read(upToCount: raster.bytes + 1) ?? Data()
        guard bytes.count == raster.bytes else { throw MediaFailure.invalidProtocol }
        return bytes
    }
}
