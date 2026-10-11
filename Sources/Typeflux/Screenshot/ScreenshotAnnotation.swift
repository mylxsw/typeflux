import AppKit

/// A region blurred, pixelated or covered on the original screenshot.
struct ScreenshotMosaic: Equatable {
    enum Shape: Equatable {
        case rect(CGRect)
        case ellipse(CGRect)
        /// A painted stroke through `points`, `width` points wide.
        case brush([CGPoint], width: CGFloat)

        /// Boxes and ellipses cover an area; a brush covers what it was painted over.
        var coversArea: Bool {
            if case .brush = self { return false }
            return true
        }
    }

    /// What inside the shape is covered.
    enum Scope: String, CaseIterable, Equatable, Codable {
        /// Everything inside the shape.
        case all
        /// Only the lines of text found inside it, so the layout around them stays clear.
        case text
    }

    enum Effect: String, CaseIterable, Equatable, Codable {
        case pixelate, blur, solid
    }

    enum Strength: Int, CaseIterable, Equatable, Codable {
        case low, medium, high
    }

    /// The smallest block, in pixels, at medium and high strength.
    static let minimumStrongBlock: CGFloat = 12

    var shape: Shape
    var effect: Effect = .pixelate
    var strength: Strength = .medium
    /// The tallest line of text under the region when it was drawn, in points; nil when none was found.
    var textHeight: CGFloat?
    /// With the text scope: the lines of text inside the shape, in points; only they are covered.
    var textRuns: [CGRect]?

    /// How far a text run is grown on every side, so the mosaic covers its letters whole.
    static let textRunMargin: CGFloat = 2

    var scope: Scope { textRuns == nil ? .all : .text }

    var frame: CGRect {
        switch shape {
        case let .rect(rect), let .ellipse(rect):
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
        case let .ellipse(rect):
            return CGPath(ellipseIn: rect.standardized, transform: nil)
        case let .brush(points, width):
            return ScreenshotAnnotation.polyline(points)
                .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
    }

    /// The paths the effect is clipped to, one after another: the shape, then the text runs when there are any.
    var clipPaths: [CGPath] {
        guard let textRuns, !textRuns.isEmpty else { return [maskPath] }
        let runs = CGMutablePath()
        for run in textRuns { runs.addRect(run.insetBy(dx: -Self.textRunMargin, dy: -Self.textRunMargin)) }
        return [maskPath, runs]
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
        case let .ellipse(rect):
            copy.shape = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case let .brush(points, width):
            copy.shape = .brush(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, width: width)
        }
        copy.textRuns = textRuns?.map { $0.offsetBy(dx: dx, dy: dy) }
        return copy
    }
}

/// One mark on a screenshot. Coordinates are points on the frozen display, with y growing
/// downward; the overlay uses the display's own origin, the exported event the global one.
// swiftlint:disable:next type_body_length
struct ScreenshotAnnotation: Equatable, Identifiable {
    enum Kind: Equatable {
        case rect(CGRect)
        case ellipse(CGRect)
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        /// A freehand pen stroke.
        case path([CGPoint])
        /// A wide translucent stroke.
        case highlight([CGPoint])
        /// `origin` is the top-left corner of the first line.
        case text(origin: CGPoint, String, fontSize: CGFloat)
        /// A numbered dot; numbers follow the order of the counters in the document.
        case counter(center: CGPoint)
        /// Text in a box with a line out to `anchor`; `origin` is the top-left corner of the text.
        case callout(anchor: CGPoint, origin: CGPoint, String, fontSize: CGFloat)
        case mosaic(ScreenshotMosaic)
    }

    let id: UUID
    var kind: Kind
    var style: ScreenshotAnnotationStyle

    /// - Parameter style: nil gives the plain default style at the size the kind's tool starts with.
    init(id: UUID = UUID(), kind: Kind, style: ScreenshotAnnotationStyle? = nil) {
        self.id = id
        self.kind = kind
        self.style = ScreenshotAnnotationStyle()
        if let style { self.style = style } else { self.style.size = tool.defaultStyle.size }
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

    /// The tool that draws this kind of annotation, for its options and size range.
    var tool: ScreenshotAnnotationTool {
        switch kind {
        case .rect: .rect
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .path: .pen
        case .highlight: .highlighter
        case .text: .text
        case .counter: .counter
        case .callout: .callout
        case .mosaic: .mosaic
        }
    }

    /// What the size slider changes: the font size of text, the width of a mosaic brush, and
    /// the style's size for the rest. Setting it keeps the style and the kind in step.
    var size: CGFloat {
        get {
            switch kind {
            case let .text(_, _, fontSize), let .callout(_, _, _, fontSize): return fontSize
            case let .mosaic(mosaic):
                if case let .brush(_, width) = mosaic.shape { return width }
                return style.size
            default: return style.size
            }
        }
        set {
            style.size = newValue
            switch kind {
            case let .text(origin, text, _):
                kind = .text(origin: origin, text, fontSize: newValue)
            case let .callout(anchor, origin, text, _):
                kind = .callout(anchor: anchor, origin: origin, text, fontSize: newValue)
            case var .mosaic(mosaic):
                if case let .brush(points, _) = mosaic.shape {
                    mosaic.shape = .brush(points, width: newValue)
                    kind = .mosaic(mosaic)
                }
            default:
                break
            }
        }
    }

    /// Text and counters keep their size; everything else can be stretched by its handles.
    var isResizable: Bool {
        switch kind {
        case .counter, .callout: false
        default: true
        }
    }

    /// The text that a double-click edits, for text and callouts.
    var editableText: (origin: CGPoint, text: String, fontSize: CGFloat)? {
        switch kind {
        case let .text(origin, text, fontSize), let .callout(_, origin, text, fontSize): return (origin, text, fontSize)
        default: return nil
        }
    }

    // MARK: Geometry

    /// The shape's own extent, without the stroke; what the selection handles surround.
    var frame: CGRect {
        switch kind {
        case let .rect(rect), let .ellipse(rect):
            return rect.standardized
        case let .line(from, to):
            return ScreenshotSelection.rect(from: from, to: to)
        case let .arrow(from, to):
            let ends = ScreenshotSelection.rect(from: from, to: to)
            guard style.arrowPath != .straight else { return ends }
            return ends.union(Self.arrowShaft(from: from, to: to, style: style).boundingBoxOfPath)
        case let .path(points), let .highlight(points):
            return Self.boundingBox(of: points)
        case let .text(origin, text, fontSize):
            let textRect = CGRect(origin: origin, size: Self.textSize(text, fontSize: fontSize, font: style.font))
            guard style.textStyle == .background else { return textRect }
            let padding = Self.textPadding(fontSize: fontSize)
            return textRect.insetBy(dx: -padding.width, dy: -padding.height)
        case let .counter(center):
            let radius = style.counterDiameter / 2
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .callout(anchor, _, _, _):
            return (calloutBox ?? .null).union(CGRect(origin: anchor, size: .zero))
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
        case let .line(from, to): copy.kind = .line(from: map(from), to: map(to))
        case let .arrow(from, to): copy.kind = .arrow(from: map(from), to: map(to))
        case let .path(points): copy.kind = .path(points.map(map))
        case let .highlight(points): copy.kind = .highlight(points.map(map))
        case let .text(origin, text, fontSize): copy.kind = .text(origin: map(origin), text, fontSize: fontSize)
        case let .counter(center): copy.kind = .counter(center: map(center))
        case let .callout(anchor, origin, text, fontSize):
            copy.kind = .callout(anchor: map(anchor), origin: map(origin), text, fontSize: fontSize)
        case let .mosaic(mosaic):
            var moved = mosaic
            switch mosaic.shape {
            case let .rect(rect): moved.shape = .rect(mapRect(rect))
            case let .ellipse(rect): moved.shape = .ellipse(mapRect(rect))
            case let .brush(points, width): moved.shape = .brush(points.map(map), width: width)
            }
            moved.textRuns = mosaic.textRuns?.map(mapRect)
            copy.kind = .mosaic(moved)
        }
        return copy
    }

    /// Whether a press at `point` lands on the mark: on the outline of an unfilled shape,
    /// anywhere on filled ones.
    func contains(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
        switch kind {
        case .rect, .ellipse:
            guard let outline = shapePath else { return false }
            if style.fill != .stroke, outline.contains(point) { return true }
            return outline.copy(strokingWithWidth: style.lineWidth + tolerance * 2, lineCap: .round,
                                lineJoin: .round, miterLimit: 10).contains(point)
        case let .line(from, to):
            return Self.distance(from: point, toSegment: from, to) <= style.lineWidth / 2 + tolerance
        case let .arrow(from, to):
            let reach = max(style.lineWidth, Self.arrowHeadLength(lineWidth: style.lineWidth) / 2) + tolerance
            guard style.arrowPath != .straight else { return Self.distance(from: point, toSegment: from, to) <= reach }
            return Self.arrowShaft(from: from, to: to, style: style)
                .copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(point)
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
        case let .callout(anchor, _, _, fontSize):
            guard let box = calloutBox else { return false }
            if box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return true }
            let reach = Self.calloutLineWidth(fontSize: fontSize) / 2 + tolerance
            if hypot(point.x - anchor.x, point.y - anchor.y) <= reach * 2 { return true }
            guard let start = calloutLineStart else { return false }
            return Self.distance(from: point, toSegment: start, anchor) <= reach
        case let .mosaic(mosaic):
            switch mosaic.shape {
            case .rect:
                return mosaic.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case let .ellipse(rect):
                return CGPath(ellipseIn: rect.standardized.insetBy(dx: -tolerance, dy: -tolerance), transform: nil)
                    .contains(point)
            case let .brush(points, width):
                return Self.polyline(points).copy(strokingWithWidth: width + tolerance * 2, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 10).contains(point)
            }
        }
    }

    /// The outline of a rectangle (with its rounded corners) or an ellipse; nil for other kinds.
    var shapePath: CGPath? {
        switch kind {
        case let .rect(rect):
            let rect = rect.standardized
            let radius = min(style.cornerRadius, rect.width / 2, rect.height / 2)
            guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case let .ellipse(rect):
            return CGPath(ellipseIn: rect.standardized, transform: nil)
        default:
            return nil
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

    // MARK: Arrows

    /// The control point of a curved arrow, or the corner of an elbow; nil for a straight one.
    static func arrowBendPoint(from: CGPoint, to: CGPoint, style: ScreenshotAnnotationStyle) -> CGPoint? {
        switch style.arrowPath {
        case .straight:
            return nil
        case .curve:
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return nil }
            let normal = CGPoint(x: -(to.y - from.y) / length, y: (to.x - from.x) / length)
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let offset = style.arrowBend * length
            return CGPoint(x: mid.x + normal.x * offset, y: mid.y + normal.y * offset)
        case .elbow:
            // Across first, then up or down; a negative bend goes up or down first.
            return style.arrowBend >= 0 ? CGPoint(x: to.x, y: from.y) : CGPoint(x: from.x, y: to.y)
        }
    }

    /// The arrow's line from `from` to `to`, without its heads.
    static func arrowShaft(from: CGPoint, to: CGPoint, style: ScreenshotAnnotationStyle) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        switch (style.arrowPath, arrowBendPoint(from: from, to: to, style: style)) {
        case let (.curve, control?): path.addQuadCurve(to: to, control: control)
        case let (.elbow, corner?): path.addLines(between: [from, corner, to])
        default: path.addLine(to: to)
        }
        return path
    }

    /// Unit directions the shaft arrives at `to` and leaves `from` in, backwards, for the heads.
    static func arrowDirections(from: CGPoint, to: CGPoint,
                                style: ScreenshotAnnotationStyle) -> (end: CGPoint, start: CGPoint) {
        func unit(_ head: CGPoint, _ tail: CGPoint) -> CGPoint? {
            let dx = head.x - tail.x, dy = head.y - tail.y, length = hypot(dx, dy)
            return length > 0.001 ? CGPoint(x: dx / length, y: dy / length) : nil
        }
        let straightEnd = unit(to, from) ?? CGPoint(x: 1, y: 0)
        let straightStart = CGPoint(x: -straightEnd.x, y: -straightEnd.y)
        guard let bend = arrowBendPoint(from: from, to: to, style: style) else { return (straightEnd, straightStart) }
        return (unit(to, bend) ?? straightEnd, unit(from, bend) ?? straightStart)
    }

    /// The handle that bends a selected curved or elbow arrow: the curve's midpoint or the elbow's corner;
    /// for a callout, the point its line ends at.
    var bendHandle: CGPoint? {
        if case let .callout(anchor, _, _, _) = kind { return anchor }
        guard case let .arrow(from, to) = kind,
              let bend = Self.arrowBendPoint(from: from, to: to, style: style) else { return nil }
        guard style.arrowPath == .curve else { return bend }
        return CGPoint(x: (from.x + 2 * bend.x + to.x) / 4, y: (from.y + 2 * bend.y + to.y) / 4)
    }

    /// The bend that puts `bendHandle` at `point`: the curve passes through it, or the elbow turns at the nearer corner.
    static func arrowBend(through point: CGPoint, from: CGPoint, to: CGPoint,
                          path: ScreenshotAnnotationStyle.ArrowPath) -> CGFloat {
        switch path {
        case .straight:
            return 0
        case .curve:
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return 0 }
            let normal = CGPoint(x: -(to.y - from.y) / length, y: (to.x - from.x) / length)
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let offset = (point.x - mid.x) * normal.x + (point.y - mid.y) * normal.y
            return min(max(2 * offset / length, -2), 2)
        case .elbow:
            let across = hypot(point.x - to.x, point.y - from.y)
            let upFirst = hypot(point.x - from.x, point.y - to.y)
            return across <= upFirst ? 1 : -1
        }
    }

    // MARK: Callouts

    /// The callout's box: its text with room around it, at least a square of the font size when empty.
    var calloutBox: CGRect? {
        guard case let .callout(_, origin, text, fontSize) = kind else { return nil }
        var size = Self.textSize(text, fontSize: fontSize, font: style.font)
        size.width = max(size.width, fontSize)
        let padding = Self.textPadding(fontSize: fontSize)
        return CGRect(origin: origin, size: size).insetBy(dx: -padding.width, dy: -padding.height)
    }

    /// Where the line leaves the box: the middle of the side facing the anchor; nil when the anchor is inside it.
    var calloutLineStart: CGPoint? {
        guard case let .callout(anchor, _, _, _) = kind, let box = calloutBox, !box.contains(anchor) else { return nil }
        let sides = [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
                     CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY)]
        return sides.min { hypot($0.x - anchor.x, $0.y - anchor.y) < hypot($1.x - anchor.x, $1.y - anchor.y) }
    }

    /// The color of the text while it is typed: a callout's box shows under the field, so its text color
    /// is the one drawn on the box; text shows in its own color.
    static func editingTextColor(_ style: ScreenshotAnnotationStyle, callout: Bool) -> CGColor {
        guard callout else { return style.color.cgColor() }
        switch style.textStyle {
        case .background: return style.color.contrastingTextColor
        case .outline: return CGColor(gray: 1, alpha: 1)
        case .plain: return style.color.cgColor()
        }
    }

    static func calloutLineWidth(fontSize: CGFloat) -> CGFloat {
        max(2, (fontSize / 7).rounded())
    }

    /// A callout dragged by its box: the box moves, the point it points at stays.
    func movingCalloutBox(dx: CGFloat, dy: CGFloat) -> ScreenshotAnnotation {
        guard case let .callout(anchor, origin, text, fontSize) = kind else { return offsetBy(dx: dx, dy: dy) }
        var moved = self
        moved.kind = .callout(anchor: anchor, origin: CGPoint(x: origin.x + dx, y: origin.y + dy), text,
                              fontSize: fontSize)
        return moved
    }

    // MARK: Counters

    /// "3" or "C" for the third counter; letters go on AA, AB… after Z.
    static func counterLabel(_ number: Int, as label: ScreenshotAnnotationStyle.CounterLabel) -> String {
        guard label == .letter, number > 0 else { return "\(number)" }
        var value = number, letters = ""
        while value > 0 {
            value -= 1
            letters = String(UnicodeScalar(UInt8(65 + value % 26))) + letters
            value /= 26
        }
        return letters
    }

    static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    /// Bold, in one of the system's own designs, so no font has to be shipped.
    static func font(size: CGFloat, family: ScreenshotAnnotationStyle.TextFont = .system) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .bold)
        let design: NSFontDescriptor.SystemDesign
        switch family {
        case .system: return system
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let descriptor = system.fontDescriptor.withDesign(design) else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    static func textAttributes(fontSize: CGFloat, color: CGColor,
                               font family: ScreenshotAnnotationStyle.TextFont = .system) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize, family: family), .foregroundColor: NSColor(cgColor: color) ?? .red]
    }

    /// The room around text on a colored block.
    static func textPadding(fontSize: CGFloat) -> CGSize {
        CGSize(width: (fontSize * 0.3).rounded(), height: (fontSize * 0.12).rounded())
    }

    /// The size the text takes when drawn; an empty line still has a line's height.
    static func textSize(_ text: String, fontSize: CGFloat,
                         font family: ScreenshotAnnotationStyle.TextFont = .system) -> CGSize {
        let attributes = textAttributes(fontSize: fontSize, color: CGColor(gray: 0, alpha: 1), font: family)
        let measured = (text.isEmpty ? " " : text as NSString)
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: ceil(text.isEmpty ? 0 : measured.width), height: ceil(measured.height))
    }
}
