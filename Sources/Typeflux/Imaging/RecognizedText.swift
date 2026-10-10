import CoreGraphics
import Foundation

/// Text found in an image, one entry per line in reading order.
struct RecognizedText: Equatable {
    struct Line: Equatable {
        /// Where a range of `text` (UTF-16) is, normalized like `boundingBox`; nil when unknown.
        typealias RangeLocator = @Sendable (NSRange) -> CGRect?

        var text: String
        var confidence: Float
        /// Normalized to the image (0...1) with the origin at the top-left corner.
        var boundingBox: CGRect
        /// Exact bounds of part of the line, from the recognizer that read it. Not compared.
        var locate: RangeLocator?

        init(text: String, confidence: Float, boundingBox: CGRect, locate: RangeLocator? = nil) {
            self.text = text
            self.confidence = confidence
            self.boundingBox = boundingBox
            self.locate = locate
        }

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.text == rhs.text && lhs.confidence == rhs.confidence && lhs.boundingBox == rhs.boundingBox
        }

        /// The line's bounds in pixels of an image of the given size.
        func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
            CGRect(x: boundingBox.minX * CGFloat(imageWidth), y: boundingBox.minY * CGFloat(imageHeight),
                   width: boundingBox.width * CGFloat(imageWidth), height: boundingBox.height * CGFloat(imageHeight))
        }
    }

    var lines: [Line]

    /// All lines joined with newlines and trimmed; nil when no text was found.
    var string: String? {
        let text = lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Converts a Vision bounding box (normalized, bottom-left origin) to a top-left origin.
    static func topLeftBox(fromVision box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
