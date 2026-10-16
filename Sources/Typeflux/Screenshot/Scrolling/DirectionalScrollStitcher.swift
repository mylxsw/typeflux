import CoreGraphics

/// Horizontal frames are transposed so both axes use the same overlap and pinned-bar checks.
enum ScrollCaptureAxis: Equatable, Sendable {
    case vertical
    case horizontal

    func orient(_ image: CGImage) -> CGImage? {
        guard self == .horizontal else { return image }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.height, height: image.width,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                                              tx: CGFloat(image.height), ty: CGFloat(image.width)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// Chooses the axis from the first accepted scroll, then keeps it for the rest of the capture.
/// Reverse scrolling never appends pixels or changes the furthest accepted frame.
struct DirectionalScrollStitcher: @unchecked Sendable {
    static let minimumAxisShift = 4
    private var joined: ScrollStitcher
    private let estimator: (any ScrollOffsetEstimating)?
    private var first: ScrollFrame?
    private var normalizedSegments: [ScrollStitcher.Segment] = []
    private(set) var axis: ScrollCaptureAxis?
    private(set) var segments: [ScrollStitcher.Segment] = []
    private(set) var footer: CGImage?

    init(maxPixels: Int = ScrollStitcher.defaultMaxPixels, estimator: (any ScrollOffsetEstimating)? = nil) {
        self.estimator = estimator
        joined = ScrollStitcher(maxPixels: maxPixels, estimator: estimator)
    }

    var maxPixelBudget: Int { joined.maxPixels }

    var isEmpty: Bool {
        joined.isEmpty
    }

    var isFull: Bool {
        joined.isFull
    }

    var width: Int {
        axis == .horizontal ? joined.height : joined.width
    }

    var height: Int {
        axis == .horizontal ? joined.width : joined.height
    }

    var frameHeight: Int {
        joined.frameHeight
    }

    var headerHeight: Int {
        joined.headerHeight
    }

    var footerHeight: Int {
        joined.footerHeight
    }

    mutating func lockAxisForAutomatic() {
        if axis == nil {
            axis = .vertical
            first = nil
        }
    }

    mutating func add(_ frame: ScrollFrame, expectedShift: Int? = nil, verticalShifts: [Int] = [], horizontalShifts: [Int] = []) -> ScrollStitcher.Outcome {
        if isEmpty {
            first = frame
            let outcome = joined.add(frame)
            refreshPreview()
            return outcome
        }
        if let axis {
            guard let normalized = normalized(frame, for: axis) else { return .unaligned }
            let outcome = joined.add(normalized, expectedShift: expectedShift, proposedShifts: axis == .vertical ? verticalShifts : horizontalShifts)
            refreshPreview()
            return outcome
        }

        // A valid forward overlap chooses the direction. An idle, reverse or unaligned frame
        // leaves the choice open, including tiny wheel movements before a horizontal scroll.
        var vertical = joined
        let outcome = vertical.add(frame, expectedShift: expectedShift, proposedShifts: verticalShifts)
        if first?.signature.hashes == frame.signature.hashes {
            return .unchanged
        }
        if accepts(outcome) {
            axis = .vertical
            joined = vertical
            first = nil
            refreshPreview()
            return outcome
        }
        if let first, let before = normalized(first, for: .horizontal),
           let after = normalized(frame, for: .horizontal) {
            var horizontal = ScrollStitcher(maxPixels: joined.maxPixels, estimator: estimator)
            _ = horizontal.add(before)
            let horizontalOutcome = horizontal.add(after, proposedShifts: horizontalShifts)
            if accepts(horizontalOutcome) {
                axis = .horizontal
                joined = horizontal
                self.first = nil
                normalizedSegments = []
                refreshPreview()
                return horizontalOutcome
            }
        }
        if case .appended = outcome {
            return .unchanged
        }
        return outcome
    }

    /// Native proposals are prepared asynchronously on an owned copy, never in synchronous getters.
    mutating func addPreparingOffsets(_ frame: ScrollFrame, expectedShift: Int? = nil,
                                     registration: (any ScrollFrameRegistering)?) async throws -> ScrollStitcher.Outcome {
        try Task.checkCancellation()
        var vertical: [Int] = [], horizontal: [Int] = []
        if let registration {
            func proposals(_ pair: (CGImage, CGImage)?) async throws -> [Int] {
                guard let pair else { return [] }
                // A native failure only removes this candidate source; hash/row checks remain mandatory.
                let values = (try? await registration.verticalShifts(from: pair.0, to: pair.1)) ?? []
                try Task.checkCancellation()
                return Array(values.prefix(2)).filter { $0 > -pair.0.height && $0 < pair.0.height }
            }
            if axis != .horizontal { vertical = try await proposals(joined.registrationPair(for: frame)) }
            if axis == .horizontal, let after = normalized(frame, for: .horizontal) {
                horizontal = try await proposals(joined.registrationPair(for: after))
            } else if axis == nil, let first, first.signature.hashes != frame.signature.hashes,
                      let before = normalized(first, for: .horizontal), let after = normalized(frame, for: .horizontal) {
                var candidate = ScrollStitcher(maxPixels: joined.maxPixels)
                _ = candidate.add(before)
                horizontal = try await proposals(candidate.registrationPair(for: after))
            }
        }
        try Task.checkCancellation()
        return add(frame, expectedShift: expectedShift, verticalShifts: vertical, horizontalShifts: horizontal)
    }

    private func normalized(_ frame: ScrollFrame, for axis: ScrollCaptureAxis) -> ScrollFrame? {
        if axis == .vertical {
            return frame
        }
        return axis.orient(frame.image).flatMap { ScrollFrame(image: $0) }
    }

    private func accepts(_ outcome: ScrollStitcher.Outcome) -> Bool {
        switch outcome {
        case let .appended(rows, _): rows >= Self.minimumAxisShift
        case .reachedLimit: true
        default: false
        }
    }

    @discardableResult
    mutating func removeLastSegment() -> Bool {
        guard joined.removeLastSegment() else { return false }
        refreshPreview()
        return true
    }

    func makeImage() -> CGImage? {
        joined.makeImage().flatMap { (axis ?? .vertical).orient($0) }
    }

    /// Only newly stored pieces are transposed; old preview images are reused.
    private mutating func refreshPreview() {
        let originals = joined.segments
        let axis = axis ?? .vertical
        segments = originals.enumerated().compactMap { index, segment in
            if index < normalizedSegments.count, index < segments.count,
               normalizedSegments[index].image === segment.image {
                return segments[index]
            }
            return axis.orient(segment.image).map {
                ScrollStitcher.Segment(image: $0, isSuspicious: segment.isSuspicious)
            }
        }
        normalizedSegments = originals
        footer = joined.footer.flatMap { axis.orient($0) }
    }
}
