import AppKit
import ImageIO
import QuickLookThumbnailing

/// Loads and caches thumbnails for clipboard panel rows and previews.
final class ClipboardThumbnailProvider {
    static let shared = ClipboardThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 300
    }

    func cachedThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(url, maxPixelSize))
    }

    func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let key = Self.key(url, maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var cgImage = await Self.imageIOThumbnail(for: url, maxPixelSize: maxPixelSize)
        if cgImage == nil {
            cgImage = await Self.quickLookThumbnail(for: url, maxPixelSize: maxPixelSize)
        }
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)#\(Int(size))" as NSString
    }

    /// Fast path for image files: decodes a downsampled thumbnail without loading the full image.
    private static func imageIOThumbnail(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary)
            else { return nil }
            return cgImage
        }.value
    }

    /// Videos, PDFs and documents: whatever Quick Look can render.
    private static func quickLookThumbnail(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixelSize / scale, height: maxPixelSize / scale),
            scale: scale,
            representationTypes: .all
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}
