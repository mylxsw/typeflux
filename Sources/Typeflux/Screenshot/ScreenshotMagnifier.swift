import CoreGraphics
import Foundation

/// The loupe beside the pointer while framing: an 11 × 9 grid of the frozen image's
/// pixels around the pointer, its position, and the color of the center pixel.
enum ScreenshotMagnifier {
    static let columns = 11
    static let rows = 9
    /// Points each sampled pixel takes in the loupe.
    static let cellSize: CGFloat = 10
    /// Room under the grid for the coordinates and the color.
    static let captionHeight: CGFloat = 38
    static let pointerOffset: CGFloat = 20

    static var size: CGSize {
        CGSize(width: CGFloat(columns) * cellSize, height: CGFloat(rows) * cellSize + captionHeight)
    }

    /// The image pixel under a point of the display, clamped to the image.
    static func pixel(at point: CGPoint, displaySize: CGSize, imageSize: ScreenPixelSize) -> CGPoint {
        guard displaySize.width > 0, displaySize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let column = Int((point.x * CGFloat(imageSize.width) / displaySize.width).rounded(.down))
        let row = Int((point.y * CGFloat(imageSize.height) / displaySize.height).rounded(.down))
        return CGPoint(x: min(max(column, 0), imageSize.width - 1), y: min(max(row, 0), imageSize.height - 1))
    }

    /// The pixels the grid shows, centered on `pixel`. Near an edge it extends past the
    /// image; the loupe leaves those cells empty.
    static func sampleRect(around pixel: CGPoint) -> CGRect {
        CGRect(x: pixel.x - CGFloat(columns / 2), y: pixel.y - CGFloat(rows / 2),
               width: CGFloat(columns), height: CGFloat(rows))
    }

    /// Where the loupe goes: below and right of the pointer, flipped to the other side
    /// of either axis when it would leave the display.
    static func frame(for pointer: CGPoint, in bounds: CGRect) -> CGRect {
        let size = size
        var left = pointer.x + pointerOffset
        var top = pointer.y + pointerOffset
        if left + size.width > bounds.maxX { left = pointer.x - pointerOffset - size.width }
        if top + size.height > bounds.maxY { top = pointer.y - pointerOffset - size.height }
        return CGRect(x: max(bounds.minX, left), y: max(bounds.minY, top), width: size.width, height: size.height)
    }

    /// The 8-bit sRGB color of one pixel; nil outside the image.
    static func color(of image: CGImage, at pixel: CGPoint) -> RGB? {
        let column = Int(pixel.x), row = Int(pixel.y)
        guard column >= 0, row >= 0, column < image.width, row < image.height,
              let single = image.cropping(to: CGRect(x: column, y: row, width: 1, height: 1)) else { return nil }
        // sRGB, so the hex matches what design tools show for the same color.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? RGB(red: bytes[0], green: bytes[1], blue: bytes[2]) : nil
    }

    struct RGB: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        /// "#2F8CFF".
        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }
}
