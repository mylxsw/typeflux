import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotExportError: Error, Equatable {
    /// The region is not on the display, or the image could not be cut.
    case emptyRegion
    case encodingFailed
}

/// Cuts the chosen region out of a frozen display at its native pixels and encodes it as PNG.
enum ScreenshotImageExporter {
    /// - Parameter rect: the region in global Quartz points.
    static func crop(_ display: ScreenSnapshot.Display, to rect: CGRect) throws -> CGImage {
        guard let pixels = ScreenCaptureGeometry.pixelRect(for: rect, displayFrame: display.frame,
                                                           imageSize: display.pixelSize),
            !pixels.isEmpty,
            let image = display.image.cropping(to: pixels)
        else { throw ScreenshotExportError.emptyRegion }
        return image
    }

    /// PNG data with a resolution of 72 dpi per point, so apps show it at its size in points.
    static func png(_ image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ScreenshotExportError.encodingFailed }
        let dpi = 72 * max(scale, 1)
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotExportError.encodingFailed }
        return data as Data
    }
}
