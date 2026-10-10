import AppKit

/// Color and size shared by every annotation tool.
struct ScreenshotAnnotationStyle: Equatable {
    enum Color: String, CaseIterable, Equatable {
        case red, yellow, green, blue, white

        /// sRGB components, matching the design's swatches.
        var rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) {
            switch self {
            case .red: (0xFF / 255, 0x4D / 255, 0x4F / 255)
            case .yellow: (0xFF / 255, 0xB0 / 255, 0x20 / 255)
            case .green: (0x29 / 255, 0xC7 / 255, 0x6E / 255)
            case .blue: (0x2F / 255, 0x8C / 255, 0xFF / 255)
            case .white: (1, 1, 1)
            }
        }

        func cgColor(alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
        }

        /// The color of a number drawn on a filled counter of this color.
        var contrastingTextColor: CGColor {
            self == .white || self == .yellow
                ? CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    enum Width: Int, CaseIterable, Equatable {
        case thin, medium, thick
    }

    var color: Color = .red
    var width: Width = .medium

    /// Outline of rectangles, ellipses and arrows, and the pen.
    var lineWidth: CGFloat { [2, 4, 6][width.rawValue] }
    var highlighterWidth: CGFloat { [12, 18, 26][width.rawValue] }
    var fontSize: CGFloat { [14, 18, 24][width.rawValue] }
    var counterDiameter: CGFloat { [20, 24, 30][width.rawValue] }
    /// How wide a mosaic brush paints.
    var brushWidth: CGFloat { [16, 28, 44][width.rawValue] }

    static let highlighterAlpha: CGFloat = 0.4
}

/// A region blurred, pixelated or covered on the original screenshot.
struct ScreenshotMosaic: Equatable {
    enum Shape: Equatable {
        case rect(CGRect)
        /// A painted stroke through `points`, `width` points wide.
        case brush([CGPoint], width: CGFloat)
    }

    enum Effect: String, CaseIterable, Equatable {
        case pixelate, blur, solid
    }

    enum Strength: Int, CaseIterable, Equatable {
        case low, medium, high
    }

    /// The smallest block, in pixels, at medium and high strength.
    static let minimumStrongBlock: CGFloat = 12

    var shape: Shape
    var effect: Effect = .pixelate
    var strength: Strength = .medium
    /// The tallest line of text under the region when it was drawn, in points; nil when none was found.
    var textHeight: CGFloat?

    var frame: CGRect {
        switch shape {
        case let .rect(rect):
            return rect.standardized
        case let .brush(points, width):
            return ScreenshotAnnotation.boundingBox(of: points).insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    /// The area the effect covers, in the same points as the shape.
    var maskPath: CGPath {
        switch shape {
        case let .rect(rect):
            return CGPath(rect: rect.standardized, transform: nil)
        case let .brush(points, width):
            return ScreenshotAnnotation.polyline(points)
                .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
    }

    /// The pixelation block, in pixels, for an image with `scale` pixels per point. Medium and
    /// high grow with the text underneath so it cannot be read, and are never under 12 pixels.
    func blockSize(scale: CGFloat) -> Int {
        let scale = max(scale, 1)
        let base: CGFloat = [5, 9, 14][strength.rawValue] * scale
        guard strength != .low else { return max(1, Int(base.rounded())) }
        let textFactor: CGFloat = strength == .medium ? 0.5 : 0.8
        let fromText = (textHeight ?? 0) * scale * textFactor
        return Int(max(base, Self.minimumStrongBlock, fromText).rounded())
    }

    /// The blur radius, in pixels, chosen the same way as `blockSize(scale:)`.
    func blurRadius(scale: CGFloat) -> Int {
        let scale = max(scale, 1)
        let base: CGFloat = [3, 6, 10][strength.rawValue] * scale
        guard strength != .low else { return max(1, Int(base.rounded())) }
        let textFactor: CGFloat = strength == .medium ? 0.4 : 0.7
        let fromText = (textHeight ?? 0) * scale * textFactor
        return Int(max(base, Self.minimumStrongBlock, fromText).rounded())
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ScreenshotMosaic {
        var copy = self
        switch shape {
        case let .rect(rect):
            copy.shape = .rect(rect.offsetBy(dx: dx, dy: dy))
        case let .brush(points, width):
            copy.shape = .brush(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, width: width)
        }
        return copy
    }
}

/// One mark on a screenshot. Coordinates are points on the frozen display, with y growing
/// downward; the overlay uses the display's own origin, the exported event the global one.
struct ScreenshotAnnotation: Equatable, Identifiable {
    enum Kind: Equatable {
        case rect(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        /// A freehand pen stroke.
        case path([CGPoint])
        /// A wide translucent stroke.
        case highlight([CGPoint])
        /// `origin` is the top-left corner of the first line.
        case text(origin: CGPoint, String, fontSize: CGFloat)
        /// A numbered dot; numbers follow the order of the counters in the document.
        case counter(center: CGPoint)
        case mosaic(ScreenshotMosaic)
    }

    let id: UUID
    var kind: Kind
    var style: ScreenshotAnnotationStyle

    init(id: UUID = UUID(), kind: Kind, style: ScreenshotAnnotationStyle = .init()) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    static let minimumFontSize: CGFloat = 6

    var isMosaic: Bool {
        if case .mosaic = kind { return true }
        return false
    }

    var mosaic: ScreenshotMosaic? {
        if case let .mosaic(mosaic) = kind { return mosaic }
        return nil
    }

    /// Text and counters keep their size; everything else can be stretched by its handles.
    var isResizable: Bool {
        if case .counter = kind { return false }
        return true
    }

    // MARK: Geometry

    /// The shape's own extent, without the stroke; what the selection handles surround.
    var frame: CGRect {
        switch kind {
        case let .rect(rect), let .ellipse(rect):
            return rect.standardized
        case let .arrow(from, to):
            return ScreenshotSelection.rect(from: from, to: to)
        case let .path(points), let .highlight(points):
            return Self.boundingBox(of: points)
        case let .text(origin, text, fontSize):
            return CGRect(origin: origin, size: Self.textSize(text, fontSize: fontSize))
        case let .counter(center):
            let radius = style.counterDiameter / 2
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .mosaic(mosaic):
            return mosaic.frame
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ScreenshotAnnotation {
        transformed { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Stretches the shape so that `old` becomes `new`; text grows with the height.
    func resized(from old: CGRect, to new: CGRect) -> ScreenshotAnnotation {
        let scaleX = old.width > 0 ? new.width / old.width : 1
        let scaleY = old.height > 0 ? new.height / old.height : 1
        var result = transformed { point in
            CGPoint(x: new.minX + (point.x - old.minX) * scaleX, y: new.minY + (point.y - old.minY) * scaleY)
        }
        if case let .text(origin, text, fontSize) = result.kind {
            result.kind = .text(origin: origin, text, fontSize: max(Self.minimumFontSize, fontSize * scaleY))
        }
        return result
    }

    private func transformed(_ map: (CGPoint) -> CGPoint) -> ScreenshotAnnotation {
        func mapRect(_ rect: CGRect) -> CGRect {
            ScreenshotSelection.rect(from: map(CGPoint(x: rect.minX, y: rect.minY)),
                                     to: map(CGPoint(x: rect.maxX, y: rect.maxY)))
        }
        var copy = self
        switch kind {
        case let .rect(rect): copy.kind = .rect(mapRect(rect))
        case let .ellipse(rect): copy.kind = .ellipse(mapRect(rect))
        case let .arrow(from, to): copy.kind = .arrow(from: map(from), to: map(to))
        case let .path(points): copy.kind = .path(points.map(map))
        case let .highlight(points): copy.kind = .highlight(points.map(map))
        case let .text(origin, text, fontSize): copy.kind = .text(origin: map(origin), text, fontSize: fontSize)
        case let .counter(center): copy.kind = .counter(center: map(center))
        case let .mosaic(mosaic):
            var moved = mosaic
            switch mosaic.shape {
            case let .rect(rect): moved.shape = .rect(mapRect(rect))
            case let .brush(points, width): moved.shape = .brush(points.map(map), width: width)
            }
            copy.kind = .mosaic(moved)
        }
        return copy
    }

    /// Whether a press at `point` lands on the mark: on the outline of an unfilled shape,
    /// anywhere on filled ones.
    func contains(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
        switch kind {
        case let .rect(rect):
            let reach = style.lineWidth / 2 + tolerance
            let rect = rect.standardized
            let inner = rect.insetBy(dx: reach, dy: reach)
            return rect.insetBy(dx: -reach, dy: -reach).contains(point) && (inner.isNull || !inner.contains(point))
        case let .ellipse(rect):
            return CGPath(ellipseIn: rect.standardized, transform: nil)
                .copy(strokingWithWidth: style.lineWidth + tolerance * 2, lineCap: .round, lineJoin: .round,
                      miterLimit: 10)
                .contains(point)
        case let .arrow(from, to):
            let reach = max(style.lineWidth, Self.arrowHeadLength(lineWidth: style.lineWidth) / 2) + tolerance
            return Self.distance(from: point, toSegment: from, to) <= reach
        case let .path(points):
            return Self.polyline(points).copy(strokingWithWidth: style.lineWidth + tolerance * 2, lineCap: .round,
                                              lineJoin: .round, miterLimit: 10).contains(point)
        case let .highlight(points):
            return Self.polyline(points).copy(strokingWithWidth: style.highlighterWidth + tolerance * 2,
                                              lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        case .text:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .counter(center):
            return hypot(point.x - center.x, point.y - center.y) <= style.counterDiameter / 2 + tolerance
        case let .mosaic(mosaic):
            switch mosaic.shape {
            case .rect:
                return mosaic.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case let .brush(points, width):
                return Self.polyline(points).copy(strokingWithWidth: width + tolerance * 2, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 10).contains(point)
            }
        }
    }

    // MARK: Helpers

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    /// The points joined by straight lines; a single point is a zero-length line, so a round cap draws a dot.
    static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        } else {
            path.addLines(between: points)
        }
        return path
    }

    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(12, lineWidth * 4)
    }

    static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .bold)
    }

    static func textAttributes(fontSize: CGFloat, color: CGColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: NSColor(cgColor: color) ?? .red]
    }

    /// The size the text takes when drawn; an empty line still has a line's height.
    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let attributes = textAttributes(fontSize: fontSize, color: CGColor(gray: 0, alpha: 1))
        let measured = (text.isEmpty ? " " : text as NSString)
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: ceil(text.isEmpty ? 0 : measured.width), height: ceil(measured.height))
    }
}
