import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import TypefluxMediaProtocol

/// Only this executable-linked module parses externally supplied image/PDF bytes.
public enum MediaDecoder {
    public static func decode(_ request: MediaRequest, input: URL) throws -> MediaResponse {
        try request.validate()
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MediaLimits.inputBytes + 1) ?? Data()
        guard data.count <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
        let items: [MediaItem]
        switch request.operation {
        case .validateGeneratedImage:
            var response = MediaResponse(id: request.id)
            response.generatedImage = try generatedImage(data)
            try response.validate(for: request)
            return response
        case .normalizeImage:
            items = [try image(data, type: request.normalization)]
        case .image:
            items = [try image(data)]
        case .pdf:
            items = try pdf(data)
        case .previewImage, .previewPDF, .previewVideo, .previewAudio:
            throw MediaFailure.invalidProtocol
        }
        var response = MediaResponse(id: request.id, items: items)
        response.normalization = request.normalization
        try response.validate(for: request)
        return response
    }

    public static func generatedImage(_ data: Data) throws -> MediaGeneratedImage {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw MediaFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw MediaFailure.unreadable }
        let metadata = MediaGeneratedImage(mediaType: type == UTType.jpeg.identifier ? "image/jpeg" : "image/png",
                                           width: width, height: height)
        do { try metadata.validate() } catch { throw MediaFailure.unreadable }
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else { throw MediaFailure.unreadable }
        return metadata
    }

    public static func image(_ data: Data, type: MediaImageType? = nil) throws -> MediaItem {
        guard data.count <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              type == nil || (data.count <= 10 * 1024 * 1024 && CGImageSourceGetType(source) as String? == type?.identifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= 100_000_000 / height,
              type == nil || (width <= 4096 && height <= 4096 && width <= 12_000_000 / height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: type == nil ? MediaLimits.imageLongEdge : 1600
              ] as CFDictionary), let encoded = jpegDataURL(image) else { throw MediaFailure.unreadable }
        return MediaItem(image: encoded)
    }

    public static func pdf(_ data: Data) throws -> [MediaItem] {
        guard data.count <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0
        else { throw MediaFailure.unreadable }
        if let text = text(pages: document.pageCount, readPage: { document.page(at: $0)?.string }) { return [text] }
        var items: [MediaItem] = []
        for index in 0 ..< min(document.pageCount, MediaLimits.scannedPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { continue }
            let scale = CGFloat(MediaLimits.imageLongEdge) / max(bounds.width, bounds.height)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let encoded = jpegDataURL(image) else { continue }
            items.append(MediaItem(image: encoded, page: index + 1))
        }
        guard !items.isEmpty else { throw MediaFailure.unreadable }
        return items
    }

    /// Stops requesting text once the retained character budget is exhausted.
    /// PDFKit's individual page allocation remains inside the disposable child.
    public static func text(pages: Int, readPage: (Int) -> String?) -> MediaItem? {
        var text = "", truncated = false
        for index in 0 ..< max(0, pages) {
            let part = readPage(index) ?? ""
            let remaining = MediaLimits.textCharacters - text.count
            if !text.isEmpty, !part.isEmpty { text += "\n" }
            text += part.prefix(max(0, remaining))
            if text.count > MediaLimits.textCharacters || part.count > remaining {
                text = String(text.prefix(MediaLimits.textCharacters)); truncated = true; break
            }
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MediaItem(text: text, truncated: truncated, pages: pages)
        }
        return nil
    }

    /// Flattens transparency onto white and encodes JPEG without metadata,
    /// shrinking until the data URL fits the per-image limit.
    public static func jpegDataURL(_ image: CGImage, limit: Int = MediaLimits.imageBytes) -> String? {
        var current = image
        for quality in [0.82, 0.7, 0.6, 0.5] {
            for _ in 0 ..< 2 {
                if let data = jpeg(current, quality: quality) {
                    let url = "data:image/jpeg;base64," + data.base64EncodedString()
                    if url.utf8.count <= limit { return url }
                }
                guard let smaller = scaled(current, by: 0.75) else { return nil }
                current = smaller
            }
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        guard let flat = scaled(image, by: 1) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? MediaJPEG.removingMetadata(data as Data) : nil
    }

    /// Redraws into an opaque RGB context, which also drops alpha and colour-space quirks.
    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
