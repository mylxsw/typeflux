import AppKit

/// Finder icons do not need Quick Look. Rasterize only the list's display size:
/// serializing every representation of an app icon can allocate tens of MB.
enum AskFinderIcon {
    @MainActor static func image(for url: URL, scale: CGFloat = 2) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let pixels = max(1, Int(ceil(28 * scale)))
        let data = await Task.detached(priority: .userInitiated) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let context = CGContext(data: nil, width: pixels, height: pixels,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil as Data? }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }.value
        guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 28, height: 28)
        return image
    }
}
