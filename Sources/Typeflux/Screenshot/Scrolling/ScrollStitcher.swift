import CoreGraphics
import Foundation

/// Finds how far the content moved between two frames, as candidates the stitcher checks row by row.
protocol ScrollOffsetEstimating: Sendable {
    /// Vertical shifts in pixels of `current` against `previous`; positive when the content moved up.
    func verticalShifts(from previous: CGImage, to current: CGImage) -> [Int]
}

/// Joins the frames of a scrolling capture into one tall image.
///
/// Each new frame is aligned with the last accepted one: the estimator (Vision) and a vote over
/// matching row hashes propose shifts, and every proposal is checked by comparing the overlapping
/// rows, and a search over all shifts by row distance adds one more. The closest one wins. Only the rows that scrolled into view are kept. A pinned header or bottom bar — rows that
/// stay put while the rest moves, found on the first scroll — is kept once: the header at the top,
/// the latest bottom bar at the end. Segments are stored separately and only joined by `makeImage()`.
/// Pure logic: the frames come in, nothing here touches the screen. A value whose images never
/// change, so a copy can do the work on another thread.
struct ScrollStitcher: @unchecked Sendable {
    static let defaultMaxPixels = 40_000_000
    /// At least this share of the compared rows must match for a shift to count as aligned.
    static let confidentMatchRatio = 0.9
    /// Below `confidentMatchRatio` but at least this, the shift is used and its segment flagged.
    static let acceptableMatchRatio = 0.6
    /// A pinned header or bottom bar takes at most this share of the frame.
    static let maxFixedShare = 3
    /// Two frames must share at least this share of their scrolling rows to be aligned.
    static let minimumOverlapDivisor = 10
    /// A row hash seen more often than this in one frame is repetitive and does not vote.
    static let maxVotesPerHash = 4
    /// The shift search compares about this many rows at each shift.
    static let searchSampleRows = 160
    /// The coarse search's best shift is settled within this many rows either way.
    static let refineRadius = 16
    /// The search hands over this many of its best shifts.
    static let searchedCandidates = 3
    /// The distance of a shift averages this share (in percent) of its closest compared rows.
    static let trimmedShare = 85
    /// A band next to the pinned bars ends once this many detailed rows in a row line up.
    static let bandEndRun = 8

    struct Segment: @unchecked Sendable {
        let image: CGImage
        /// The overlap did not check out well; the preview marks it and the user can undo it.
        let isSuspicious: Bool

        var height: Int { image.height }
    }

    enum Outcome: Equatable {
        /// The first frame.
        case started
        case appended(rows: Int, suspicious: Bool)
        /// Nothing moved.
        case unchanged
        /// The content moved down (scrolled back up): nothing new.
        case scrolledBack
        /// No shift lines the frames up; the frame is dropped.
        case unaligned
        /// The size limit is reached; `rows` were still added. Later frames add nothing.
        case reachedLimit(rows: Int)
    }

    private struct Record {
        var segment: Segment
        /// The frame this segment came from, which the next frame is aligned with.
        var reference: ScrollFrameSignature
        /// That frame's bottom bar, shown at the end of the image.
        var footer: CGImage?
    }

    struct Candidate: Equatable {
        var shift: Int
        var ratio: Double
        /// The average distance between the closest compared rows.
        var distance: Double
        /// Only plain rows overlapped, so the match proves little.
        var isAmbiguous: Bool
    }

    let maxPixels: Int
    private let estimator: (any ScrollOffsetEstimating)?
    private var records: [Record] = []
    /// The last accepted frame's image, for the estimator. Gone after an undo.
    private var referenceImage: CGImage?
    private var fixedRowsKnown = false

    private(set) var width = 0
    private(set) var frameHeight = 0
    private(set) var headerHeight = 0
    private(set) var footerHeight = 0
    private(set) var isFull = false

    init(maxPixels: Int = Self.defaultMaxPixels, estimator: (any ScrollOffsetEstimating)? = nil) {
        self.maxPixels = maxPixels
        self.estimator = estimator
    }

    var segments: [Segment] { records.map(\.segment) }
    var footer: CGImage? { records.last?.footer }
    var isEmpty: Bool { records.isEmpty }
    /// The joined image's height in pixels.
    var height: Int { records.reduce(0) { $0 + $1.segment.height } + (footer?.height ?? 0) }
    var pixelCount: Int { width * height }

    // MARK: Adding frames

    /// - Parameter expectedShift: how far the content was just scrolled, in pixels, when known; one
    ///   more candidate, checked like the others.
    mutating func add(_ frame: ScrollFrame, expectedShift: Int? = nil) -> Outcome {
        guard let last = records.last else { return start(with: frame) }
        guard frame.width == width, frame.height == frameHeight else { return .unaligned }
        let previous = last.reference, current = frame.signature
        if previous.hashes == current.hashes { return .unchanged }
        if isFull { return .reachedLimit(rows: 0) }
        let fixed = fixedRowsKnown ? (header: headerHeight, footer: footerHeight)
            : Self.fixedRows(previous, current)
        let middle = fixed.header ..< frameHeight - fixed.footer
        let shifts = candidateShifts(previous: previous, current: current, frame: frame, middle: middle)
            + (expectedShift.map { [$0] } ?? [])
        // Before the bars are known both may widen; after, only the top, for this comparison alone:
        // a header that follows the content (an editor's sticky scroll) changes from frame to frame.
        guard let (best, bars) = Self.best(of: shifts, fixed: fixed, widening: fixedRowsKnown ? .header : .both,
                                           previous: previous, current: current),
              best.ratio >= Self.acceptableMatchRatio else { return .unaligned }
        if best.shift == 0 { return .unchanged }
        if best.shift < 0 { return .scrolledBack }
        let suspicious = best.ratio < Self.confidentMatchRatio || best.isAmbiguous
        return append(frame, shift: best.shift, header: bars.header,
                      footer: fixedRowsKnown ? footerHeight : bars.footer, suspicious: suspicious)
    }

    private mutating func start(with frame: ScrollFrame) -> Outcome {
        width = frame.width
        frameHeight = frame.height
        guard let copy = Self.copyRows(of: frame.image, from: 0, count: frame.height) else { return .unaligned }
        records = [Record(segment: Segment(image: copy, isSuspicious: false), reference: frame.signature)]
        referenceImage = frame.image
        isFull = pixelCount >= maxPixels
        return .started
    }

    private mutating func append(_ frame: ScrollFrame, shift: Int, header: Int, footer: Int,
                                 suspicious: Bool) -> Outcome {
        let bottom = frameHeight - footer
        let footerImage = footer > 0 ? Self.copyRows(of: frame.image, from: bottom, count: footer) : nil
        if !fixedRowsKnown {
            // The first frame was kept whole; now that its bottom bar is known, it moves to the end.
            if footer > 0, var first = records.first,
               let top = Self.copyRows(of: first.segment.image, from: 0, count: bottom) {
                first.footer = Self.copyRows(of: first.segment.image, from: bottom, count: footer)
                first.segment = Segment(image: top, isSuspicious: first.segment.isSuspicious)
                records[0] = first
            }
            headerHeight = header
            footerHeight = footer
            fixedRowsKnown = true
        }
        let rowsBefore = records.reduce(0) { $0 + $1.segment.height } + footer
        let room = maxPixels / max(width, 1) - rowsBefore
        guard room > 0 else {
            isFull = true
            return .reachedLimit(rows: 0)
        }
        let rows = min(shift, room)
        guard let image = Self.copyRows(of: frame.image, from: bottom - shift, count: rows) else { return .unaligned }
        records.append(Record(segment: Segment(image: image, isSuspicious: suspicious), reference: frame.signature,
                              footer: footerImage))
        referenceImage = frame.image
        if rows < shift || pixelCount >= maxPixels {
            isFull = true
            return .reachedLimit(rows: rows)
        }
        return .appended(rows: rows, suspicious: suspicious)
    }

    /// Drops the newest segment; the next frame is aligned with the one before it.
    /// - Returns: false when only the first frame is left.
    @discardableResult
    mutating func removeLastSegment() -> Bool {
        guard records.count > 1 else { return false }
        records.removeLast()
        referenceImage = nil
        isFull = pixelCount >= maxPixels
        return true
    }

    // MARK: Alignment

    /// Some apps blur or fade the content scrolling under a pinned header or bottom bar (the scroll edge
    /// effect of macOS 26), so the rows next to the bars belong to neither the bars nor the content.
    /// When rows right next to the bars do not line up at the found shift while the rest does, they
    /// join the bars.
    /// - Returns: nil when there is no such band, or the shift does not line up better without it.
    static func widenedFixedRows(_ fixed: (header: Int, footer: Int), shift: Int, footer widensFooter: Bool = true,
                                 previous: ScrollFrameSignature,
                                 current: ScrollFrameSignature) -> (fixed: (header: Int, footer: Int),
                                                                     candidate: Candidate)? {
        let height = current.height
        let middle = fixed.header ..< height - fixed.footer
        let overlap = middle.count - shift
        guard shift > 0, overlap > 0 else { return nil }
        let rows = middle.lowerBound ..< middle.lowerBound + overlap
        // The band ends at the last row that does not line up before a run of rows that do: sticky
        // lines can leave a few matching rows between them.
        func band(_ order: [Int]) -> Int {
            var last: Int?
            var matchedRun = 0
            for (index, row) in order.enumerated() {
                let matches = current.row(row, matches: row + shift, of: previous)
                if !matches {
                    last = index
                    matchedRun = 0
                } else if current.isDetailed[row] || previous.isDetailed[row + shift] {
                    matchedRun += 1
                    if matchedRun >= bandEndRun { break }
                }
            }
            return last.map { $0 + 1 } ?? 0
        }
        let limit = height / maxFixedShare
        let header = min(fixed.header + band(Array(rows)), limit)
        let footer = widensFooter ? min(fixed.footer + band(rows.reversed()), limit) : fixed.footer
        guard header != fixed.header || footer != fixed.footer,
              let candidate = evaluate(shift: shift, previous: previous, current: current,
                                       middle: header ..< height - footer) else { return nil }
        return ((header, footer), candidate)
    }

    /// Rows at the top and bottom that kept their place and content: a pinned header and bottom bar.
    static func fixedRows(_ previous: ScrollFrameSignature,
                          _ current: ScrollFrameSignature) -> (header: Int, footer: Int) {
        let limit = previous.height / maxFixedShare
        var header = 0
        while header < limit, previous.hashes[header] == current.hashes[header] { header += 1 }
        var footer = 0
        while footer < limit, previous.hashes[previous.height - 1 - footer] == current.hashes[previous.height - 1 - footer] {
            footer += 1
        }
        return (header, footer)
    }

    /// The shifts worth checking: the estimator's, the hash vote's and the row-distance search's.
    private func candidateShifts(previous: ScrollFrameSignature, current: ScrollFrameSignature, frame: ScrollFrame,
                                 middle: Range<Int>) -> [Int] {
        var shifts: [Int] = []
        if let estimator, let referenceImage {
            let rect = CGRect(x: 0, y: middle.lowerBound, width: width, height: middle.count)
            if let before = referenceImage.cropping(to: rect), let after = frame.image.cropping(to: rect) {
                shifts += estimator.verticalShifts(from: before, to: after)
            }
        }
        if let voted = Self.votedShift(previous: previous, current: current, middle: middle) { shifts.append(voted) }
        // Redrawn content seldom matches hash for hash, and repeating layouts (lists, tables) can make
        // a wrong shift look right row by row; the search by row distance covers both.
        shifts += Self.searchedShifts(previous: previous, current: current, middle: middle)
        return shifts
    }

    /// Which pinned bars a candidate may widen while it is judged.
    enum Widening {
        case none, header, both
    }

    /// Checks every shift and keeps the best. A forward shift may widen the pinned bars by the band
    /// next to them that never lines up (`widenedFixedRows`), and is judged that way when it helps:
    /// an animated header, a blurred edge or an editor's sticky lines would otherwise hide the right shift.

    static func best(of shifts: [Int], fixed: (header: Int, footer: Int), widening: Widening,
                     previous: ScrollFrameSignature, current: ScrollFrameSignature)
        -> (candidate: Candidate, fixed: (header: Int, footer: Int))? {
        let middle = fixed.header ..< current.height - fixed.footer
        let judged = Set(shifts).compactMap { shift -> (candidate: Candidate, fixed: (header: Int, footer: Int))? in
            guard let plain = evaluate(shift: shift, previous: previous, current: current, middle: middle) else {
                return nil
            }
            if widening != .none, shift > 0,
               let widened = widenedFixedRows(fixed, shift: shift, footer: widening == .both, previous: previous,
                                              current: current),
               isBetter(widened.candidate, than: plain) {
                return widened
            }
            return (plain, fixed)
        }
        return judged.min { isBetter($0.candidate, than: $1.candidate) }
    }

    /// Whether a candidate's overlapping rows are closer; among equally close ones, the one with the
    /// most matching rows, then the smallest shift. Closeness comes first: in a list whose rows repeat,
    /// a wrong shift can match nearly every row loosely while only the right one matches closely.
    static func isBetter(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        if lhs.ratio != rhs.ratio { return lhs.ratio > rhs.ratio }
        return abs(lhs.shift) < abs(rhs.shift)
    }

    /// The shifts at which a sample of detailed rows is closest to the other frame, best first: found
    /// with the coarse profiles, then each settled with the fine boxes nearby. Coarse profiles of code
    /// or text are much alike from line to line, so a coarse best can be a few rows off, and a band
    /// that never lines up (an editor's sticky lines) can make a wrong shift look best; the few best
    /// are all handed to the row-by-row check.
    static func searchedShifts(previous: ScrollFrameSignature, current: ScrollFrameSignature,
                               middle: Range<Int>) -> [Int] {
        let detailed = middle.filter { current.isDetailed[$0] }
        guard !detailed.isEmpty else { return [] }
        let step = max(1, detailed.count / searchSampleRows)
        let sample = stride(from: 0, to: detailed.count, by: step).map { detailed[$0] }
        let limit = middle.count - max(1, middle.count / minimumOverlapDivisor)
        guard limit >= 0 else { return [] }
        let coarse = closestShifts(in: -limit ... limit, sample: sample, middle: middle) {
            current.profileDistance($0, to: $1, of: previous)
        }
        var shifts: [Int] = []
        for shift in coarse.prefix(searchedCandidates) {
            let nearby = max(-limit, shift - refineRadius) ... min(limit, shift + refineRadius)
            let fine = closestShifts(in: nearby, sample: sample, middle: middle) {
                current.distance($0, to: $1, of: previous)
            }
            let settled = fine.first ?? shift
            if !shifts.contains(settled) { shifts.append(settled) }
        }
        return shifts
    }

    /// The shifts in `shifts` at which the sample rows are closest, best first, at least
    /// `refineRadius` apart. Closeness is the average of the closest `trimmedShare` of the rows.
    private static func closestShifts(in shifts: ClosedRange<Int>, sample: [Int], middle: Range<Int>,
                                      distance: (Int, Int) -> Int) -> [Int] {
        var scored: [(shift: Int, distance: Double)] = []
        var distances: [Int] = []
        for shift in shifts {
            distances.removeAll(keepingCapacity: true)
            for row in sample where middle.contains(row + shift) {
                distances.append(distance(row, row + shift))
            }
            // A handful of rows at the very edge proves nothing.
            guard distances.count >= max(3, sample.count / minimumOverlapDivisor) else { continue }
            distances.sort()
            let kept = distances.prefix(max(1, distances.count * trimmedShare / 100))
            scored.append((shift, Double(kept.reduce(0, +)) / Double(kept.count)))
        }
        scored.sort { $0.distance != $1.distance ? $0.distance < $1.distance : abs($0.shift) < abs($1.shift) }
        var best: [Int] = []
        for candidate in scored where best.allSatisfy({ abs($0 - candidate.shift) > refineRadius }) {
            best.append(candidate.shift)
            if best.count == searchedCandidates { break }
        }
        return best
    }

    /// The shift most matching detailed rows agree on.
    static func votedShift(previous: ScrollFrameSignature, current: ScrollFrameSignature,
                           middle: Range<Int>) -> Int? {
        var rowsByHash: [UInt64: [Int]] = [:]
        for row in middle where previous.isDetailed[row] {
            rowsByHash[previous.hashes[row], default: []].append(row)
        }
        var votes: [Int: Int] = [:]
        for row in middle where current.isDetailed[row] {
            guard let matches = rowsByHash[current.hashes[row]], matches.count <= maxVotesPerHash else { continue }
            for match in matches { votes[match - row, default: 0] += 1 }
        }
        let best = votes.max { lhs, rhs in
            lhs.value == rhs.value ? abs(lhs.key) > abs(rhs.key) : lhs.value < rhs.value
        }
        return best.map(\.key)
    }

    /// How well the frames line up at `shift`: the share of overlapping detailed rows that match,
    /// and how far apart they are on average.
    static func evaluate(shift: Int, previous: ScrollFrameSignature, current: ScrollFrameSignature,
                         middle: Range<Int>) -> Candidate? {
        let overlap = middle.count - abs(shift)
        guard overlap >= max(1, middle.count / minimumOverlapDivisor) else { return nil }
        let rows = max(0, -shift) ..< max(0, -shift) + overlap
        var matched = 0, plainMatched = 0
        var distances: [Int] = []
        for offset in rows {
            let row = middle.lowerBound + offset, other = row + shift
            let matches = current.row(row, matches: other, of: previous)
            if current.isDetailed[row] || previous.isDetailed[other] {
                distances.append(current.distance(row, to: other, of: previous))
                if matches { matched += 1 }
            } else if matches {
                plainMatched += 1
            }
        }
        if distances.isEmpty {
            // Only plain rows overlap: it lines up if they all match, but nothing proves the shift.
            return Candidate(shift: shift, ratio: plainMatched == overlap ? 1 : 0, distance: 0, isAmbiguous: true)
        }
        // The closest rows only: a band that never lines up (a blurred edge, a video) should not
        // outweigh everything else.
        distances.sort()
        let kept = distances.prefix(max(1, distances.count * trimmedShare / 100))
        return Candidate(shift: shift, ratio: Double(matched) / Double(distances.count),
                         distance: Double(kept.reduce(0, +)) / Double(kept.count), isAmbiguous: false)
    }

    // MARK: Images

    /// The segments one under another, then the bottom bar.
    func makeImage() -> CGImage? {
        let height = height
        guard let first = records.first, width > 0, height > 0 else { return nil }
        let image = first.segment.image
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var top = 0
        for piece in segments.map(\.image) + (footer.map { [$0] } ?? []) {
            // Core Graphics counts y from the bottom.
            context.draw(piece, in: CGRect(x: 0, y: height - top - piece.height, width: piece.width,
                                           height: piece.height))
            top += piece.height
        }
        return context.makeImage()
    }

    /// `count` rows from `from` down, copied out so the frame they came from can be released.
    static func copyRows(of image: CGImage, from: Int, count: Int) -> CGImage? {
        guard count > 0, from >= 0, from + count <= image.height,
              let rows = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: count))
        else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: rows.width, height: rows.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(rows, in: CGRect(x: 0, y: 0, width: rows.width, height: rows.height))
        return context.makeImage()
    }
}
