import AppKit

/// The joined image so far, scaled across the capture axis and pinned to its newest edge. The newest
/// segment is outlined, doubtful segments are tinted orange and a pinned top or left bar green.
@MainActor
final class ScrollCapturePreviewView: NSView {
    static let inset: CGFloat = 8
    static let suspiciousColor = NSColor.systemOrange
    static let headerColor = NSColor.systemGreen

    /// A segment as drawn, in the view's points.
    struct Placement: Equatable {
        var frame: CGRect
        var isSuspicious: Bool
        var isNewest: Bool
    }

    struct Layout {
        var segments: [Placement]
        var header: CGRect?
        var footer: CGRect?
    }

    var preview = ScrollCapturePreview() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Places the segments and fixed bars along the capture axis, keeping the newest pixels visible.
    static func layout(_ preview: ScrollCapturePreview, in bounds: CGRect) -> Layout {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard preview.width > 0, area.width > 0, area.height > 0 else {
            return Layout(segments: [], header: nil, footer: nil)
        }
        let horizontal = preview.axis == .horizontal
        let crossLength = horizontal ? preview.segments.first?.image.height ?? 0 : preview.width
        guard crossLength > 0 else { return Layout(segments: [], header: nil, footer: nil) }
        let scale = (horizontal ? area.height : area.width) / CGFloat(crossLength)
        func length(_ image: CGImage) -> CGFloat {
            CGFloat(horizontal ? image.width : image.height) * scale
        }
        func rect(at position: CGFloat, length: CGFloat) -> CGRect {
            horizontal
                ? CGRect(x: position, y: area.minY, width: length, height: area.height)
                : CGRect(x: area.minX, y: position, width: area.width, height: length)
        }
        let footerLength = preview.footer.map(length) ?? 0
        let total = preview.segments.reduce(CGFloat(0)) { $0 + length($1.image) } + footerLength
        var position = (horizontal ? area.minX : area.minY) - max(0, total - (horizontal ? area.width : area.height))
        var placements: [Placement] = []
        for (index, segment) in preview.segments.enumerated() {
            let extent = length(segment.image)
            placements.append(Placement(frame: rect(at: position, length: extent),
                                        isSuspicious: segment.isSuspicious,
                                        isNewest: index > 0 && index == preview.segments.count - 1))
            position += extent
        }
        let header = preview.headerHeight > 0 ? placements.first.map {
            rect(at: horizontal ? $0.frame.minX : $0.frame.minY, length: CGFloat(preview.headerHeight) * scale)
        } : nil
        let footer = preview.footer == nil ? nil : rect(at: position, length: footerLength)
        return Layout(segments: placements, header: header, footer: footer)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        card.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        card.stroke()
        let layout = Self.layout(preview, in: bounds)
        context.saveGState()
        context.clip(to: bounds.insetBy(dx: Self.inset, dy: Self.inset))
        for (placement, segment) in zip(layout.segments, preview.segments)
            where placement.frame.intersects(dirtyRect) {
            ScreenshotRenderer.drawImage(segment.image, in: placement.frame, context: context)
            if placement.isSuspicious {
                context.setFillColor(Self.suspiciousColor.withAlphaComponent(0.28).cgColor)
                context.fill(placement.frame)
            }
        }
        if let footer = preview.footer, let frame = layout.footer {
            ScreenshotRenderer.drawImage(footer, in: frame, context: context)
        }
        if let header = layout.header {
            context.setFillColor(Self.headerColor.withAlphaComponent(0.25).cgColor)
            context.fill(header)
            context.setStrokeColor(Self.headerColor.cgColor)
            context.setLineWidth(1)
            context.stroke(header.insetBy(dx: 0.5, dy: 0.5))
        }
        for placement in layout.segments where placement.isNewest || placement.isSuspicious {
            let color = placement.isSuspicious ? Self.suspiciousColor : ScreenshotOverlayChromeView.accent
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2)
            context.stroke(placement.frame.insetBy(dx: 1, dy: 1))
        }
        context.restoreGState()
    }
}
