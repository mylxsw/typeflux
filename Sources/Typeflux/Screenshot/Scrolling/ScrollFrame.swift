import Accelerate
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
    /// Runs for every captured frame, millions of pixels on a large display. All per-pixel and per-box
    /// work runs in Accelerate and the standard library's hasher, so it stays fast in unoptimized
    /// builds too.
    init(gray: [UInt8], width: Int, height: Int) {
        let compared = Self.comparedWidth(width)
        let bins = max(1, min(Self.profileBins, compared))
        let samples = max(1, min(Self.fineSamples, compared))
        var hashes = [UInt64](repeating: 0, count: height)
        var detailed = [Bool](repeating: false, count: height)
        var profiles = [UInt8](repeating: 0, count: height * bins)
        var fine = [UInt8](repeating: 0, count: height * samples)
        let coarseBoxes = Boxes(width: compared, count: bins)
        let fineBoxes = Boxes(width: compared, count: samples)
        var levels = [Float](repeating: 0, count: max(compared, 1))
        // `prefix[k]` is the sum of the first `k` levels: exact, as it stays far below 2^24.
        var prefix = [Float](repeating: 0, count: compared + 1)
        var scratch = [Float](repeating: 0, count: 2 * (samples + 1))
        let length = vDSP_Length(compared)
        gray.withUnsafeBufferPointer { pixels in
            guard let base = pixels.baseAddress, compared > 0 else { return }
            levels.withUnsafeMutableBufferPointer { levels in
                prefix.withUnsafeMutableBufferPointer { prefix in
                    scratch.withUnsafeMutableBufferPointer { scratch in
                        profiles.withUnsafeMutableBufferPointer { profiles in
                            fine.withUnsafeMutableBufferPointer { fine in
                                let levels = levels.baseAddress!, prefix = prefix.baseAddress!
                                for row in 0 ..< height {
                                    let start = base + row * width
                                    var hasher = Hasher()
                                    hasher.combine(bytes: UnsafeRawBufferPointer(start: start, count: compared))
                                    hashes[row] = UInt64(bitPattern: Int64(hasher.finalize()))
                                    vDSP_vfltu8(start, 1, levels, 1, length)
                                    var low: Float = 0, high: Float = 0
                                    vDSP_minv(levels, 1, &low, length)
                                    vDSP_maxv(levels, 1, &high, length)
                                    detailed[row] = high - low >= Float(Self.detailThreshold)
                                    // vDSP's running sum leaves out the first level; add it back.
                                    var one: Float = 1, first = levels[0]
                                    vDSP_vrsum(levels, 1, &one, prefix + 1, 1, length)
                                    vDSP_vsadd(prefix + 1, 1, &first, prefix + 1, 1, length)
                                    prefix[0] = 0
                                    coarseBoxes.average(prefix, scratch: scratch.baseAddress!,
                                                        into: profiles.baseAddress! + row * bins)
                                    fineBoxes.average(prefix, scratch: scratch.baseAddress!,
                                                      into: fine.baseAddress! + row * samples)
                                }
                            }
                        }
                    }
                }
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
        hashes[row] == other.hashes[otherRow] ? 0 : fineDifference(row, otherRow, other).mean
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

    /// Called for every candidate row pair while frames are aligned, so the arithmetic runs in
    /// Accelerate.
    private static func difference(_ lhs: [UInt8], _ lhsStart: Int, _ rhs: [UInt8], _ rhsStart: Int,
                                   count: Int, comparable: Bool) -> (mean: Int, max: Int) {
        guard comparable, count > 0, lhsStart >= 0, rhsStart >= 0, lhsStart + count <= lhs.count,
              rhsStart + count <= rhs.count else { return (255, 255) }
        return lhs.withUnsafeBufferPointer { lhs in
            rhs.withUnsafeBufferPointer { rhs in
                withUnsafeTemporaryAllocation(of: Float.self, capacity: count * 2) { scratch in
                    let left = scratch.baseAddress!, right = left + count, length = vDSP_Length(count)
                    vDSP_vfltu8(lhs.baseAddress! + lhsStart, 1, left, 1, length)
                    vDSP_vfltu8(rhs.baseAddress! + rhsStart, 1, right, 1, length)
                    vDSP_vsub(right, 1, left, 1, left, 1, length)
                    var sum: Float = 0, largest: Float = 0
                    vDSP_svemg(left, 1, &sum, length)
                    vDSP_maxmgv(left, 1, &largest, length)
                    return (Int(sum) / count, Int(largest))
                }
            }
        }
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

/// Equal boxes of columns: box `b` holds the columns `c` with `c * count / width == b`, a contiguous
/// range. Averages a row's levels over them from its prefix sums.
private struct Boxes {
    let count: Int
    /// One-based positions in the prefix sums of each box's first column, then the end.
    private let bounds: [vDSP_Length]
    private let sizes: [Float]

    init(width: Int, count: Int) {
        self.count = count
        let starts = (0 ... count).map { box in (box * width + count - 1) / max(count, 1) }
        bounds = starts.map { vDSP_Length($0 + 1) }
        sizes = (0 ..< count).map { Float(max(starts[$0 + 1] - starts[$0], 1)) }
    }

    /// Each box's sum divided by its size, rounded down, as integer division would. The sums are exact;
    /// vDSP's division is not, so half a column is added first: `(sum + 0.5) / size` lies at least
    /// `0.5 / size` (at least 1/1024 here) from the next integer, far more than the division's error.
    func average(_ prefix: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>,
                 into output: UnsafeMutablePointer<UInt8>) {
        let sums = scratch + count + 1, length = vDSP_Length(count)
        var half: Float = 0.5
        bounds.withUnsafeBufferPointer { bounds in
            sizes.withUnsafeBufferPointer { sizes in
                vDSP_vgathr(prefix, bounds.baseAddress!, 1, scratch, 1, vDSP_Length(count + 1))
                vDSP_vsub(scratch, 1, scratch + 1, 1, sums, 1, length)
                vDSP_vsadd(sums, 1, &half, sums, 1, length)
                vDSP_vdiv(sizes.baseAddress!, 1, sums, 1, sums, 1, length)
                vDSP_vfixu8(sums, 1, output, 1, length)
            }
        }
    }
}
