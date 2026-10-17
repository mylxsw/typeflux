import CoreGraphics
import Foundation

/// Cuts a tall image into overlapping horizontal bands, and joins what was read from them.
/// Pure geometry: rows are pixels from the top of the image.
enum ImageTiling {
    /// Rows `start ..< end` of the image.
    struct Band: Equatable {
        var start: Int
        var end: Int

        var height: Int { end - start }
    }

    // MARK: Text recognition

    /// Vision reads a band of about this many pixels well; taller images are cut up.
    static let textBandHeight = 4000
    /// Rows two neighbouring bands share, so a line cut by one band is whole in the other.
    static let textBandOverlap = 200

    /// Bands at most `height` tall, each sharing `overlap` rows with the one before.
    /// One band covers an image that fits; an empty image has none.
    static func bands(imageHeight: Int, height: Int = textBandHeight, overlap: Int = textBandOverlap) -> [Band] {
        guard imageHeight > 0 else { return [] }
        let height = max(height, 1)
        guard imageHeight > height else { return [Band(start: 0, end: imageHeight)] }
        let overlap = min(max(overlap, 0), height - 1)
        let step = height - overlap
        var result: [Band] = []
        var start = 0
        while true {
            let end = min(start + height, imageHeight)
            result.append(Band(start: start, end: end))
            if end == imageHeight { break }
            start += step
        }
        // A last band that would be mostly overlap is folded into a full-height one ending at the bottom.
        if result.count > 1, let last = result.last, last.height < height {
            result[result.count - 1] = Band(start: max(imageHeight - height, 0), end: imageHeight)
        }
        return result
    }

    /// Joins the lines read from each band into one reading of the whole image, band after
    /// band, each in the order Vision read it (which follows columns better than sorting would).
    ///
    /// Each pair of neighbouring bands splits their shared rows in the middle: a band keeps
    /// only the lines whose centre is on its side, so a line read twice is kept once. A line
    /// still repeated next to the split (read slightly higher in one band) is dropped too.
    /// - Parameters:
    ///   - results: one reading per band, in band order, boxes normalized to that band.
    ///   - imageSize: the whole image in pixels.
    static func merge(_ results: [(band: Band, text: RecognizedText)], imageSize: CGSize) -> RecognizedText {
        guard imageSize.width > 0, imageSize.height > 0 else { return RecognizedText(lines: []) }
        var kept: [(line: RecognizedText.Line, band: Int)] = []
        for (index, result) in results.enumerated() {
            let band = result.band
            let lower = index == 0 ? -CGFloat.infinity
                : CGFloat(band.start + results[index - 1].band.end) / 2
            let upper = index == results.count - 1 ? CGFloat.infinity
                : CGFloat(results[index + 1].band.start + band.end) / 2
            for line in result.text.lines {
                let rect = pixelRect(of: line, in: band, imageWidth: imageSize.width)
                guard rect.midY >= lower, rect.midY < upper else { continue }
                var placed = line
                placed.boundingBox = CGRect(x: rect.minX / imageSize.width, y: rect.minY / imageSize.height,
                                            width: rect.width / imageSize.width,
                                            height: rect.height / imageSize.height)
                placed.locate = line.locate.map { locate in
                    let translated: RecognizedText.Line.RangeLocator = { [band] range in
                        locate(range).map { box in
                            let pixels = CGRect(x: box.minX * imageSize.width,
                                                y: CGFloat(band.start) + box.minY * CGFloat(band.height),
                                                width: box.width * imageSize.width,
                                                height: box.height * CGFloat(band.height))
                            return CGRect(x: pixels.minX / imageSize.width, y: pixels.minY / imageSize.height,
                                          width: pixels.width / imageSize.width,
                                          height: pixels.height / imageSize.height)
                        }
                    }
                    return translated
                }
                if kept.contains(where: { $0.band != index && isDuplicate($0.line, placed, imageSize: imageSize) }) {
                    continue
                }
                kept.append((placed, index))
            }
        }
        return RecognizedText(lines: kept.map(\.line))
    }

    /// A line in a band, in pixels of the whole image.
    static func pixelRect(of line: RecognizedText.Line, in band: Band, imageWidth: CGFloat) -> CGRect {
        let height = CGFloat(band.height)
        return CGRect(x: line.boundingBox.minX * imageWidth,
                      y: CGFloat(band.start) + line.boundingBox.minY * height,
                      width: line.boundingBox.width * imageWidth,
                      height: line.boundingBox.height * height)
    }

    /// The same text at nearly the same place: one line read by two bands.
    static func isDuplicate(_ first: RecognizedText.Line, _ second: RecognizedText.Line, imageSize: CGSize) -> Bool {
        guard normalized(first.text) == normalized(second.text) else { return false }
        let firstHeight = first.boundingBox.height * imageSize.height
        let secondHeight = second.boundingBox.height * imageSize.height
        let tolerance = max(firstHeight, secondHeight, 1)
        let dy = abs(first.boundingBox.midY - second.boundingBox.midY) * imageSize.height
        let dx = abs(first.boundingBox.minX - second.boundingBox.minX) * imageSize.width
        return dy <= tolerance && dx <= tolerance * 2
    }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }

    // MARK: Images for a question

    /// Why an image was not cut into pieces for a question.
    enum SliceError: Error, Equatable {
        /// It would need this many pieces, more than a question may carry.
        case tooManySlices(Int)
        case empty
    }

    /// Cuts an image into pieces a model can read: each, once shrunk to `longEdge` across,
    /// is at most `longEdge` tall, and neighbouring pieces share `overlapFraction` of a piece.
    /// An image that already fits (or is wider than tall) is one piece; it is only shrunk.
    /// - Returns: the pieces as rectangles in the image's pixels, top to bottom.
    static func slices(imageSize: CGSize, longEdge: Int = 2048, overlapFraction: CGFloat = 0.1,
                       maximumCount: Int = 8) -> Result<[CGRect], SliceError> {
        let width = imageSize.width.rounded(), height = imageSize.height.rounded()
        guard width >= 1, height >= 1, longEdge > 0 else { return .failure(.empty) }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        // Shrinking to the long edge happens later; a slice is as tall as the long edge after it.
        let shrink = min(1, CGFloat(longEdge) / width)
        let sliceHeight = (CGFloat(longEdge) / shrink).rounded(.down)
        guard height > sliceHeight else { return .success([whole]) }
        let overlap = (sliceHeight * min(max(overlapFraction, 0), 0.9)).rounded(.down)
        let step = sliceHeight - overlap
        let count = Int(((height - overlap) / step).rounded(.up))
        guard count <= maximumCount else { return .failure(.tooManySlices(count)) }
        let rects = (0 ..< count).map { index -> CGRect in
            // The last piece ends at the bottom, sharing a little more with the one before.
            let top = min(CGFloat(index) * step, height - sliceHeight)
            return CGRect(x: 0, y: top, width: width, height: sliceHeight)
        }
        return .success(rects)
    }
}
