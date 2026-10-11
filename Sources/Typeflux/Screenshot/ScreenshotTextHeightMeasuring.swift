import CoreGraphics
import Foundation
import Vision

/// Finds the text under a mosaic: how tall it is, so medium and strong mosaics can use blocks
/// big enough to make it unreadable, and where its lines are, for mosaics that only cover text.
protocol ScreenshotTextHeightMeasuring {
    /// The height of the tallest line of text in the image, in its pixels; nil when there is none.
    func tallestLineHeight(in image: CGImage) -> CGFloat?
    /// Where the lines of text are, in the image's pixels with the origin at the top-left corner.
    func textLines(in image: CGImage) -> [CGRect]
}

extension ScreenshotTextHeightMeasuring {
    func textLines(in image: CGImage) -> [CGRect] { [] }
}

/// Vision's text detector: it only locates text, without reading it, so it is quick enough
/// to run when a mosaic is drawn.
struct VisionTextHeightMeasurer: ScreenshotTextHeightMeasuring {
    func tallestLineHeight(in image: CGImage) -> CGFloat? {
        let request = VNDetectTextRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        return Self.tallest(normalizedBoxes: (request.results ?? []).map(\.boundingBox), imageHeight: image.height)
    }

    func textLines(in image: CGImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return Self.pixelRects(normalizedBoxes: (request.results ?? []).map(\.boundingBox),
                               imageWidth: image.width, imageHeight: image.height)
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
