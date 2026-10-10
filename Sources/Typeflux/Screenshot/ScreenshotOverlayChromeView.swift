import AppKit

/// Draws the framing interface over a frozen display: outline, handles, size label,
/// guides, loupe and key hint. It only draws; the overlay view under it takes the input.
@MainActor
final class ScreenshotOverlayChromeView: NSView {
    struct Loupe: Equatable {
        var frame: CGRect
        /// The sampled pixels that lie on the image; nil when none do.
        var image: CGImage?
        /// Where those pixels start within the grid, in cells.
        var imageOffset: CGPoint
        /// How many cells they cover.
        var imageSize: CGSize
        var coordinates: String
        var color: String
    }

    struct Model: Equatable {
        var selection: CGRect?
        var hovered: CGRect?
        var handles = false
        var sizeLabel: String?
        /// Where the guides cross; nil hides them.
        var pointer: CGPoint?
        var loupe: Loupe?
        var hint: String?
    }

    static let accent = NSColor(srgbRed: 0x2F / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1)
    static let handleSize: CGFloat = 8
    static let pillHeight: CGFloat = 22

    var model = Model() {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Input goes to the overlay view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let pointer = model.pointer { drawGuides(through: pointer, in: context) }
        if let hovered = model.hovered {
            context.setStrokeColor(Self.accent.cgColor)
            context.setLineWidth(3)
            context.stroke(hovered.insetBy(dx: 1.5, dy: 1.5))
        }
        if let selection = model.selection {
            context.setStrokeColor(Self.accent.cgColor)
            context.setLineWidth(1.5)
            context.stroke(selection.insetBy(dx: -0.75, dy: -0.75))
            if model.handles { drawHandles(around: selection, in: context) }
        }
        if let label = model.sizeLabel, let target = model.selection ?? model.hovered {
            let size = Self.pillSize(for: label)
            var origin = CGPoint(x: target.minX, y: target.minY - size.height - 6)
            if origin.y < bounds.minY { origin.y = target.minY + 6; origin.x = target.minX + 6 }
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            drawPill(label, in: CGRect(origin: origin, size: size))
        }
        if let hint = model.hint, let selection = model.selection {
            drawPill(hint, in: Self.hintFrame(for: selection, size: Self.pillSize(for: hint), in: bounds))
        }
        if let loupe = model.loupe { drawLoupe(loupe, in: context) }
    }

    /// Below the region, or above it, or inside its bottom-right corner when neither fits.
    static func hintFrame(for selection: CGRect, size: CGSize, in bounds: CGRect) -> CGRect {
        let gap: CGFloat = 8
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + gap)
        if origin.y + size.height > bounds.maxY {
            origin.y = selection.minY - gap - size.height
            if origin.y < bounds.minY { origin.y = selection.maxY - gap - size.height; origin.x -= gap }
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    static func pillSize(for text: String) -> CGSize {
        let width = (text as NSString).size(withAttributes: labelAttributes).width
        return CGSize(width: ceil(width) + 16, height: pillHeight)
    }

    private func drawPill(_ text: String, in frame: CGRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        let size = (text as NSString).size(withAttributes: Self.labelAttributes)
        (text as NSString).draw(at: CGPoint(x: frame.minX + 8, y: frame.midY - size.height / 2),
                                withAttributes: Self.labelAttributes)
    }

    private func drawHandles(around rect: CGRect, in context: CGContext) {
        for handle in ScreenshotSelection.Handle.allCases {
            let center = ScreenshotSelection.point(for: handle, in: rect)
            let frame = CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2,
                               width: Self.handleSize, height: Self.handleSize)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: frame)
            context.setStrokeColor(Self.accent.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: frame)
        }
    }

    private func drawGuides(through point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(Self.accent.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: bounds.minX, y: point.y + 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y + 0.5))
        context.move(to: CGPoint(x: point.x + 0.5, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x + 0.5, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private func drawLoupe(_ loupe: Loupe, in context: CGContext) {
        let cell = ScreenshotMagnifier.cellSize
        let grid = CGRect(x: loupe.frame.minX, y: loupe.frame.minY,
                          width: CGFloat(ScreenshotMagnifier.columns) * cell,
                          height: CGFloat(ScreenshotMagnifier.rows) * cell)
        context.saveGState()
        NSBezierPath(roundedRect: loupe.frame, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.withAlphaComponent(0.85).setFill()
        loupe.frame.fill()
        if let image = loupe.image {
            let target = CGRect(x: grid.minX + loupe.imageOffset.x * cell, y: grid.minY + loupe.imageOffset.y * cell,
                                width: loupe.imageSize.width * cell, height: loupe.imageSize.height * cell)
            // CGContext draws images bottom-up; flip locally so the pixels keep their order.
            context.saveGState()
            context.interpolationQuality = .none
            context.translateBy(x: target.minX, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: target.size))
            context.restoreGState()
        }
        let center = CGRect(x: grid.minX + CGFloat(ScreenshotMagnifier.columns / 2) * cell,
                            y: grid.minY + CGFloat(ScreenshotMagnifier.rows / 2) * cell, width: cell, height: cell)
        context.setStrokeColor(Self.accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(center)
        let caption = [loupe.coordinates, loupe.color].filter { !$0.isEmpty }
        for (index, line) in caption.enumerated() {
            (line as NSString).draw(at: CGPoint(x: grid.minX + 8, y: grid.maxY + 4 + CGFloat(index) * 15),
                                    withAttributes: Self.labelAttributes)
        }
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(roundedRect: loupe.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
    }
}
