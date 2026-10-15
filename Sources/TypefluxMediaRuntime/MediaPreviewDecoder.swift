import AppKit
import ImageIO
import PDFKit
import TypefluxMediaProtocol

public enum MediaPreviewDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) throws -> MediaResponse {
        try request.validate()
        guard let options = request.preview, !request.operation.isAV else { throw MediaFailure.invalidProtocol }
        let input = directory.appendingPathComponent("input")
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MediaLimits.inputBytes + 1) ?? Data()
        guard data.count <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
        var response = MediaResponse(id: request.id)
        if request.operation == .previewImage {
            let image = try image(data, options: options)
            let raster = try write(image, index: 0, page: nil, directory: directory)
            response.preview = .init(rasters: [raster])
        } else {
            response.preview = try pdf(data, options: options, directory: directory)
        }
        try response.validate(for: request)
        return response
    }

    private static func image(_ data: Data, options: MediaPreviewOptions) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= 100_000_000 / height else { throw MediaFailure.unreadable }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5 ... 8).contains(orientation)
        let w = Double(rotated ? height : width), h = Double(rotated ? width : height)
        let scale = min(1, min(Double(options.width) / w, Double(options.height) / h))
        let maximum = max(1, Int(floor(max(w, h) * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ] as CFDictionary) else { throw MediaFailure.unreadable }
        return image
    }

    private static func pdf(_ data: Data, options: MediaPreviewOptions, directory: URL) throws -> MediaPreviewResult {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0
        else { throw MediaFailure.unreadable }
        let indices = options.page.flatMap { (1 ... document.pageCount).contains($0) ? [$0 - 1] : nil }
            ?? Array(0 ..< min(3, document.pageCount))
        let rasters = try indices.enumerated().map { outputIndex, index in
            guard let page = document.page(at: index), let reference = page.pageRef
            else { throw MediaFailure.unreadable }
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width.isFinite, size.height.isFinite, size.width >= 0.01, size.height >= 0.01,
                  size.width <= 1e9, size.height <= 1e9
            else { throw MediaFailure.unreadable }
            let scale = min(Double(options.width) / size.width, Double(options.height) / size.height)
            let width = max(1, min(options.width, Int(ceil(size.width * scale))))
            let height = max(1, min(options.height, Int(ceil(size.height * scale))))
            let context = try context(width: width, height: height)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.concatenate(reference.getDrawingTransform(.mediaBox, rect: rect, rotate: 0,
                                                              preserveAspectRatio: true))
            context.drawPDFPage(reference)
            if options.page == index + 1, let passage = options.passage, let text = page.string {
                context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.05, alpha: 0.38))
                for range in MediaPreviewText.ranges(in: text, passage: passage) {
                    for line in page.selection(for: range)?.selectionsByLine() ?? [] {
                        context.fill(line.bounds(for: page).insetBy(dx: -1, dy: -1))
                    }
                }
            }
            return try write(context, index: outputIndex, page: index + 1, directory: directory)
        }
        return .init(rasters: rasters, pages: document.pageCount)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= MediaPreviewOptions.maxEdge,
              height <= MediaPreviewOptions.maxEdge, width * height <= MediaPreviewOptions.maxPixels,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaFailure.tooLarge }
        return context
    }

    static func write(_ image: CGImage, index: Int, page: Int?, directory: URL) throws -> MediaRaster {
        let context = try context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try write(context, index: index, page: page, directory: directory)
    }

    private static func write(_ context: CGContext, index: Int, page: Int?, directory: URL) throws -> MediaRaster {
        let raster = MediaRaster(width: context.width, height: context.height, page: page)
        guard let bytes = context.data else { throw MediaFailure.unavailable }
        try Data(bytes: bytes, count: raster.bytes).write(
            to: directory.appendingPathComponent(MediaRaster.filename(index)), options: .withoutOverwriting)
        return raster
    }
}
