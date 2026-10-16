import CoreGraphics
import Foundation

/// Finds the text under a mosaic: how tall it is, so medium and strong mosaics can use blocks
/// big enough to make it unreadable, and where its lines are, for mosaics that only cover text.
struct ScreenshotTextGeometry {
    var lines: [CGRect]
    var height: CGFloat?
}

protocol ScreenshotTextHeightMeasuring {
    func geometry(in image: CGImage) async throws -> ScreenshotTextGeometry
}

/// Detection runs in the disposable media child.
struct VisionTextHeightMeasurer: ScreenshotTextHeightMeasuring {
    var recognizer = VisionImageTextRecognizer()
    func geometry(in image: CGImage) async throws -> ScreenshotTextGeometry {
        let result = try await recognizer.textGeometry(in: image)
        let lines = Self.pixelRects(normalizedBoxes: result.boxes, imageWidth: image.width, imageHeight: image.height)
        return ScreenshotTextGeometry(lines: lines, height: lines.map(\.height).max())
    }

    /// Vision's boxes are normalized with the origin at the bottom-left corner.
    static func pixelRects(normalizedBoxes: [CGRect], imageWidth: Int, imageHeight: Int) -> [CGRect] {
        let width = CGFloat(imageWidth), height = CGFloat(imageHeight)
        return normalizedBoxes.map { box in
            CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
                   height: box.height * height)
        }
    }

    static func tallest(normalizedBoxes: [CGRect], imageHeight: Int) -> CGFloat? {
        normalizedBoxes.map { $0.height * CGFloat(imageHeight) }.max()
    }
}
