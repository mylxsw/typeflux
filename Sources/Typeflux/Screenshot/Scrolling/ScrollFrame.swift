import CoreGraphics
import Foundation

/// One captured frame of the scrolling region, with the row summary used to compare it to others.
struct ScrollFrame: @unchecked Sendable {
    let image: CGImage
    let signature: ScrollFrameSignature

    init?(image: CGImage) {
        guard let signature = ScrollFrameSignature(image: image) else { return nil }
        self.image = image
        self.signature = signature
    }

    init(image: CGImage, signature: ScrollFrameSignature) {
        self.image = image
        self.signature = signature
    }

    var width: Int { image.width }
    var height: Int { image.height }
}

/// A frame reduced to one record per pixel row: an exact hash of the row's gray levels, its gray
/// levels averaged over small boxes for tolerant comparisons, a coarse profile for a quick search,
/// and whether the row has enough detail to align on. Plain rows (blank space, rules) match almost
/// anywhere, so they never vote on an offset.
///
/// Apps do not always redraw scrolled content pixel for pixel (text is often rasterized again at its
/// new position), so rows are compared by how far apart their boxes are, not only by hash. The boxes
/// stay small enough to tell list items apart by their labels: in a list whose layout repeats, a
/// coarse comparison would line up any item with any other.
struct ScrollFrameSignature: Equatable, Sendable {
    /// Columns are averaged into this many bins for the coarse profile.
    static let profileBins = 32
    /// Columns are averaged into at most this many boxes for the fine comparison (about 4 pixels each
    /// on a 2× display).
    static let fineSamples = 384
    /// A row whose darkest and lightest pixels are closer than this has too little detail to align on.
    static let detailThreshold: UInt8 = 24
    /// Rows whose boxes differ by at most this much on average count as the same row...
    static let rowTolerance = 6
    /// ...as long as no single box differs by more than this. A list item's label (its number, its
    /// name) changes only a few boxes, but by a lot; an average alone would not see it.
    static let boxTolerance = 80
    /// Overlay scroll bars come and go at the right edge while content scrolls, so this many pixels
    /// there (at most an eighth of the width) are left out of every comparison.
    static let scrollBarMargin = 36

    /// The columns compared, from the left.
    static func comparedWidth(_ width: Int) -> Int {
        width - min(scrollBarMargin, width / 8)
    }

    let width: Int
    let height: Int
    let hashes: [UInt64]
    let isDetailed: [Bool]
    /// `height × bins` coarse averages, row by row.
    let profiles: [UInt8]
    let bins: Int
    /// `height × samples` fine averages, row by row.
    let fine: [UInt8]
    let samples: Int

    init(width: Int, height: Int, hashes: [UInt64], isDetailed: [Bool], profiles: [UInt8], bins: Int,
         fine: [UInt8], samples: Int) {
        self.width = width
        self.height = height
        self.hashes = hashes
        self.isDetailed = isDetailed
        self.profiles = profiles
        self.bins = bins
        self.fine = fine
        self.samples = samples
    }

    init?(image: CGImage) {
        guard let gray = Self.grayPixels(of: image) else { return nil }
        self.init(gray: gray, width: image.width, height: image.height)
    }

    /// - Parameter gray: one byte per pixel, top row first.
    init(gray: [UInt8], width: Int, height: Int) {
        let compared = Self.comparedWidth(width)
        let bins = max(1, min(Self.profileBins, compared))
        let samples = max(1, min(Self.fineSamples, compared))
        var hashes = [UInt64](repeating: 0, count: height)
        var detailed = [Bool](repeating: false, count: height)
        var profiles = [UInt8](repeating: 0, count: height * bins)
        var fine = [UInt8](repeating: 0, count: height * samples)
        let coarse = BoxAverager(width: compared, boxes: bins)
        let small = BoxAverager(width: compared, boxes: samples)
        gray.withUnsafeBufferPointer { pixels in
            for row in 0 ..< height {
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                var low: UInt8 = 255, high: UInt8 = 0
                let start = row * width
                for column in 0 ..< compared {
                    let value = pixels[start + column]
                    hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01B3
                    low = min(low, value)
                    high = max(high, value)
                }
                hashes[row] = hash
                detailed[row] = high - low >= Self.detailThreshold
                coarse.average(pixels, start: start, into: &profiles, at: row * bins)
                small.average(pixels, start: start, into: &fine, at: row * samples)
            }
        }
        self.init(width: width, height: height, hashes: hashes, isDetailed: detailed, profiles: profiles, bins: bins,
                  fine: fine, samples: samples)
    }

    /// The same row content, exactly or within the tolerances.
    func row(_ row: Int, matches otherRow: Int, of other: ScrollFrameSignature) -> Bool {
        if hashes[row] == other.hashes[otherRow] { return true }
        let difference = fineDifference(row, otherRow, other)
        return difference.mean <= Self.rowTolerance && difference.max <= Self.boxTolerance
    }

    /// The average difference between two rows' fine boxes; 255 when they cannot be compared.
    func distance(_ row: Int, to otherRow: Int, of other: ScrollFrameSignature) -> Int {
        fineDifference(row, otherRow, other).mean
    }

    /// The average difference between two rows' coarse profiles, for a quick search; 255 when they
    /// cannot be compared.
    func profileDistance(_ row: Int, to otherRow: Int, of other: ScrollFrameSignature) -> Int {
        Self.difference(profiles, row * bins, other.profiles, otherRow * other.bins, count: bins,
                        comparable: bins == other.bins).mean
    }

    private func fineDifference(_ row: Int, _ otherRow: Int, _ other: ScrollFrameSignature) -> (mean: Int, max: Int) {
        Self.difference(fine, row * samples, other.fine, otherRow * other.samples, count: samples,
                        comparable: samples == other.samples)
    }

    private static func difference(_ lhs: [UInt8], _ lhsStart: Int, _ rhs: [UInt8], _ rhsStart: Int,
                                   count: Int, comparable: Bool) -> (mean: Int, max: Int) {
        guard comparable, count > 0 else { return (255, 255) }
        var sum = 0, largest = 0
        for index in 0 ..< count {
            let left = Int(lhs[lhsStart + index]), right = Int(rhs[rhsStart + index])
            let difference = left > right ? left - right : right - left
            sum += difference
            largest = max(largest, difference)
        }
        return (sum / count, largest)
    }

    /// The image's gray levels, one byte per pixel, top row first.
    static func grayPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// Averages a row of gray levels over equal boxes of columns.
private struct BoxAverager {
    let width: Int
    let boxes: Int
    /// The box of each column.
    private let boxOfColumn: [Int]
    private let counts: [Int]

    init(width: Int, boxes: Int) {
        self.width = width
        self.boxes = boxes
        boxOfColumn = (0 ..< width).map { $0 * boxes / max(width, 1) }
        var counts = [Int](repeating: 0, count: boxes)
        for box in boxOfColumn { counts[box] += 1 }
        self.counts = counts
    }

    func average(_ pixels: UnsafeBufferPointer<UInt8>, start: Int, into output: inout [UInt8], at offset: Int) {
        var sums = [Int](repeating: 0, count: boxes)
        for column in 0 ..< width { sums[boxOfColumn[column]] += Int(pixels[start + column]) }
        for box in 0 ..< boxes { output[offset + box] = UInt8(sums[box] / max(counts[box], 1)) }
    }
}
