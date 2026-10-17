import AppKit

/// Presentation around the flattened screenshot; all lengths are in the source display's points.
struct ScreenshotBeautification: Equatable {
    enum Background: String, CaseIterable {
        case transparent, white, charcoal, sky, mint, sunset, lavender

        var colors: [CGColor] {
            switch self {
            case .transparent: []
            case .white: [CGColor(gray: 1, alpha: 1)]
            case .charcoal: [CGColor(gray: 0.12, alpha: 1)]
            case .sky: [Self.color(0x5368ED), Self.color(0x74DDF0)]
            case .mint: [Self.color(0xC3EF96), Self.color(0x66D3F6)]
            case .sunset: [Self.color(0xFF737D), Self.color(0xFFD18B)]
            case .lavender: [Self.color(0x9267D9), Self.color(0xEABDEB)]
            }
        }

        private static func color(_ rgb: Int) -> CGColor {
            CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    var isEnabled = false
    var background: Background = .mint
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadow: CGFloat = 0.3

    var normalized: Self {
        var result = self
        result.padding = Self.clamp(padding, to: 0 ... 160)
        result.cornerRadius = Self.clamp(cornerRadius, to: 0 ... 80)
        result.shadow = Self.clamp(shadow, to: 0 ... 1)
        return result
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}

/// The preview and every output use the same compositor, after annotations and redactions are flattened.
enum ScreenshotBeautificationRenderer {
    static func canvasSize(for imageSize: CGSize, scale: CGFloat,
                           settings: ScreenshotBeautification) throws -> CGSize {
        guard scale.isFinite, scale > 0 else { throw ScreenshotExportError.encodingFailed }
        let padding = (settings.normalized.padding * scale).rounded()
        let width = imageSize.width + padding * 2
        let height = imageSize.height + padding * 2
        // Reject unreasonable allocations before converting to Int or asking Core Graphics for memory.
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 65_536, height <= 65_536,
              width * height <= 100_000_000 else { throw ScreenshotExportError.encodingFailed }
        return CGSize(width: width, height: height)
    }

    static func render(_ image: CGImage, scale: CGFloat, settings: ScreenshotBeautification) throws -> CGImage {
        guard settings.isEnabled else { return image }
        let settings = settings.normalized
        let size = try canvasSize(for: CGSize(width: image.width, height: image.height),
                                  scale: scale, settings: settings)
        let padding = (settings.padding * scale).rounded()
        let width = size.width, height = size.height
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: ScreenshotMosaicEffects.colorSpace(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotExportError.encodingFailed }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = settings.background.colors
        if colors.count == 1 {
            context.setFillColor(colors[0])
            context.fill(canvas)
        } else if let first = colors.first,
                  let gradient = CGGradient(colorsSpace: first.colorSpace, colors: colors as CFArray,
                                            locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        let rect = CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = min(settings.cornerRadius * scale, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if settings.shadow > 0, padding > 0 {
            context.saveGState()
            context.addRect(canvas)
            context.addPath(path)
            context.clip(using: .evenOdd)
            context.setShadow(offset: CGSize(width: 0, height: 6 * scale), blur: 18 * scale,
                              color: CGColor(gray: 0, alpha: settings.shadow * 0.65))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        context.addPath(path)
        context.clip()
        ScreenshotRenderer.drawImage(image, in: rect, context: context)
        guard let result = context.makeImage() else { throw ScreenshotExportError.encodingFailed }
        return result
    }
}
