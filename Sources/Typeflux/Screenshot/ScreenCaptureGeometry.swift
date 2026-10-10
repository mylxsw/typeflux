import CoreGraphics
import Foundation

/// Coordinate and size arithmetic shared by screen capture and the screenshot overlay.
enum ScreenCaptureGeometry {
    /// The pixel size to capture a display at. `.fitting` scales the point size down
    /// so the longer side stays within the limit, and never scales it up.
    static func pixelSize(pointSize: CGSize, scale: CGFloat,
                          resolution: ScreenCaptureRequest.Resolution) -> ScreenPixelSize {
        let factor: Double
        switch resolution {
        case .native:
            factor = Double(max(scale, 1))
        case let .fitting(maxDimension):
            factor = min(1, Double(maxDimension) / Double(max(pointSize.width, pointSize.height, 1)))
        }
        // Rounded, so a factor such as 1600 / 1920 cannot leave the longer side at 1599.
        return ScreenPixelSize(width: max(1, Int((Double(pointSize.width) * factor).rounded())),
                               height: max(1, Int((Double(pointSize.height) * factor).rounded())))
    }

    /// Pixels per point of a display mode; 1 when the mode reports no usable size.
    static func backingScale(pixelWidth: Int, pointWidth: Int) -> CGFloat {
        guard pixelWidth > 0, pointWidth > 0 else { return 1 }
        return max(1, CGFloat(pixelWidth) / CGFloat(pointWidth))
    }

    /// Converts between Quartz (top-left origin) and AppKit (bottom-left origin) global
    /// coordinates. Both are anchored to the primary display, so the conversion is its
    /// own inverse.
    static func flipped(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flipped(_ point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// The part of `rect` (global Quartz points) that lies on a display, in that
    /// display image's pixels, rounded outward to whole pixels. Nil when it misses the display.
    static func pixelRect(for rect: CGRect, displayFrame: CGRect, imageSize: ScreenPixelSize) -> CGRect? {
        let visible = rect.intersection(displayFrame)
        guard !visible.isNull, !visible.isEmpty, displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let scaleX = CGFloat(imageSize.width) / displayFrame.width
        let scaleY = CGFloat(imageSize.height) / displayFrame.height
        let pixels = CGRect(x: (visible.minX - displayFrame.minX) * scaleX,
                            y: (visible.minY - displayFrame.minY) * scaleY,
                            width: visible.width * scaleX, height: visible.height * scaleY).integral
        return pixels.intersection(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
    }

    /// Redraws an image at another pixel size; returns it untouched when the size already matches.
    static func resized(_ image: CGImage, to size: ScreenPixelSize) -> CGImage? {
        if image.width == size.width && image.height == size.height { return image }
        // An 8-bit RGBA context needs an RGB color space; keep the image's own when it is one.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}
