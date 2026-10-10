import CoreGraphics
import Foundation
import Vision

/// Finds how tall the text under a mosaic is, so medium and strong mosaics can use blocks
/// big enough to make it unreadable.
protocol ScreenshotTextHeightMeasuring {
    /// The height of the tallest line of text in the image, in its pixels; nil when there is none.
    func tallestLineHeight(in image: CGImage) -> CGFloat?
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

    static func tallest(normalizedBoxes: [CGRect], imageHeight: Int) -> CGFloat? {
        normalizedBoxes.map { $0.height * CGFloat(imageHeight) }.max()
    }
}
