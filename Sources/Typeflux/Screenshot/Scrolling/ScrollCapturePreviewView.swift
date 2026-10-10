import AppKit

/// The joined image so far, scaled to the strip's width and pinned to its newest rows. The newest
/// segment is outlined, doubtful segments are tinted orange and a pinned header green.
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

    var preview = ScrollCapturePreview() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the segments, the header and the bottom bar go: scaled to the width and, when taller
    /// than the strip, shifted up so the newest rows show.
    static func layout(_ preview: ScrollCapturePreview,
                       in bounds: CGRect) -> (segments: [Placement], header: CGRect?, footer: CGRect?) {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard preview.width > 0, area.width > 0, area.height > 0 else { return ([], nil, nil) }
        let scale = area.width / CGFloat(preview.width)
        let footerHeight = CGFloat(preview.footer?.height ?? 0) * scale
        let total = preview.segments.reduce(CGFloat(0)) { $0 + CGFloat($1.height) * scale } + footerHeight
        var top = area.minY - max(0, total - area.height)
        var placements: [Placement] = []
        for (index, segment) in preview.segments.enumerated() {
            let height = CGFloat(segment.height) * scale
            placements.append(Placement(frame: CGRect(x: area.minX, y: top, width: area.width, height: height),
                                        isSuspicious: segment.isSuspicious,
                                        isNewest: index > 0 && index == preview.segments.count - 1))
            top += height
        }
        let header = preview.headerHeight > 0 ? placements.first.map {
            CGRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width,
                   height: CGFloat(preview.headerHeight) * scale)
        } : nil
        let footer = preview.footer == nil ? nil
            : CGRect(x: area.minX, y: top, width: area.width, height: footerHeight)
        return (placements, header, footer)
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
