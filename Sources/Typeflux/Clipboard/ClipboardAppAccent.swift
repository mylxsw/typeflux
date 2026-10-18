import AppKit

/// The color of a shelf card's header: the dominant color of the source app's icon, darkened
/// enough for white text. Computed once per app and kept for the process lifetime.
enum ClipboardAppAccent {
    /// Used when the icon is unknown or has no colorful pixels (a grey or black icon).
    static let neutral = NSColor(srgbRed: 0.36, green: 0.38, blue: 0.42, alpha: 1)
    /// Voice results: Typeflux orange.
    static let voice = NSColor(srgbRed: 0.98, green: 0.45, blue: 0.27, alpha: 1)
    /// Permanent snippets: indigo, so they never look like a copy from some app.
    static let snippet = NSColor(srgbRed: 0.39, green: 0.37, blue: 0.86, alpha: 1)
    /// White header text stays readable up to this brightness.
    static let maximumBrightness: CGFloat = 0.72

    private static let sampleEdge = 16
    @MainActor private static var cache: [String: NSColor] = [:]

    /// The cached color for `key` (a bundle ID), computing it from `icon` the first time.
    @MainActor
    static func color(for key: String, icon: NSImage) -> NSColor {
        if let cached = cache[key] { return cached }
        let color = dominantColor(of: icon) ?? neutral
        if cache.count >= 256 { cache.removeAll() }
        cache[key] = color
        return color
    }

    /// The average of the icon's saturated, opaque pixels, or `nil` when there are almost none.
    static func dominantColor(of image: NSImage) -> NSColor? {
        guard let pixels = samplePixels(of: image) else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        var count = 0
        for pixel in pixels {
            let color = NSColor(srgbRed: pixel.red, green: pixel.green, blue: pixel.blue, alpha: 1)
            // Saturation already rules out white and grey; very dark pixels carry no hue.
            guard pixel.alpha > 0.5, color.saturationComponent > 0.25,
                  color.brightnessComponent >= 0.2 else { continue }
            red += pixel.red
            green += pixel.green
            blue += pixel.blue
            count += 1
        }
        // Fewer than 1 in 16 pixels colored: the icon is essentially grey.
        guard count * 16 >= pixels.count, count > 0 else { return nil }
        let average = NSColor(
            srgbRed: red / CGFloat(count), green: green / CGFloat(count), blue: blue / CGFloat(count), alpha: 1
        )
        return readable(average)
    }

    /// Caps brightness so white text on the color keeps its contrast.
    static func readable(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        guard rgb.brightnessComponent > maximumBrightness else { return rgb }
        return NSColor(
            hue: rgb.hueComponent, saturation: rgb.saturationComponent,
            brightness: maximumBrightness, alpha: 1
        ).usingColorSpace(.sRGB) ?? rgb
    }

    private struct Pixel {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    /// Draws the icon into a small sRGB bitmap; unpremultiplies so edge pixels keep their hue.
    private static func samplePixels(of image: NSImage) -> [Pixel]? {
        let edge = sampleEdge
        // Tagged sRGB so the bytes read back are sRGB components, whatever the display profile.
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                  bytesPerRow: 0, bitsPerPixel: 0
              )?.retagging(with: .sRGB),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var pixels: [Pixel] = []
        pixels.reserveCapacity(edge * edge)
        for row in 0 ..< edge {
            for column in 0 ..< edge {
                let offset = row * rep.bytesPerRow + column * 4
                let alpha = CGFloat(data[offset + 3]) / 255
                guard alpha > 0 else { continue }
                pixels.append(Pixel(
                    red: min(1, CGFloat(data[offset]) / 255 / alpha),
                    green: min(1, CGFloat(data[offset + 1]) / 255 / alpha),
                    blue: min(1, CGFloat(data[offset + 2]) / 255 / alpha),
                    alpha: alpha
                ))
            }
        }
        return pixels.isEmpty ? nil : pixels
    }
}
