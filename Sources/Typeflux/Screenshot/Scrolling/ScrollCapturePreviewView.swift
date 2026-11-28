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

    private lazy var viewportView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(view)
        return view
    }()
    private(set) var liveViewport: CGImage?

    /// Keeps the current viewport visible while the stitcher verifies new content. The inset stays
    /// separate from the confirmed image so a reverse scroll or an unaligned frame adds no pixels.
    func showViewport(_ thumbnail: CGImage?) {
        guard liveViewport !== thumbnail else { return }
        liveViewport = thumbnail
        viewportView.isHidden = thumbnail == nil
        viewportView.image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        if let thumbnail {
            let area = bounds.insetBy(dx: Self.inset, dy: Self.inset)
            let scale = min(area.width * 0.64 / CGFloat(thumbnail.width),
                            area.height * 0.25 / CGFloat(thumbnail.height))
            let width = CGFloat(thumbnail.width) * scale, height = CGFloat(thumbnail.height) * scale
            viewportView.frame = CGRect(x: area.maxX - width, y: area.maxY - height, width: width, height: height)
        }
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
        // Without a known scroll start, the newest segment alone.
        let newest = preview.newestStart > 0 ? preview.newestStart : preview.segments.count - 1
        for (index, segment) in preview.segments.enumerated() {
            let extent = length(segment.image)
            placements.append(Placement(frame: rect(at: position, length: extent),
                                        isSuspicious: segment.isSuspicious,
                                        isNewest: index > 0 && index >= newest))
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
        let area = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        context.saveGState()
        context.clip(to: area)
        context.interpolationQuality = .medium
        for (placement, segment) in zip(layout.segments, preview.segments)
            where placement.frame.intersects(dirtyRect) && placement.frame.intersects(area) {
            ScreenshotRenderer.drawImage(segment.thumbnail ?? segment.image, in: placement.frame, context: context)
            if placement.isSuspicious {
                context.setFillColor(Self.suspiciousColor.withAlphaComponent(0.28).cgColor)
                context.fill(placement.frame)
            }
        }
        if let footer = preview.footer, let frame = layout.footer {
            ScreenshotRenderer.drawImage(preview.footerThumbnail ?? footer, in: frame, context: context)
        }
        if let header = layout.header {
            context.setFillColor(Self.headerColor.withAlphaComponent(0.25).cgColor)
            context.fill(header)
            context.setStrokeColor(Self.headerColor.cgColor)
            context.setLineWidth(1)
            context.stroke(header.insetBy(dx: 0.5, dy: 0.5))
        }
        // The newest scroll is one outline, however many slices it was joined in.
        if let newest = Self.newestFrame(layout) {
            context.setStrokeColor(ScreenshotOverlayChromeView.accent.cgColor)
            context.setLineWidth(2)
            context.stroke(newest.insetBy(dx: 1, dy: 1))
        }
        for placement in layout.segments where placement.isSuspicious {
            context.setStrokeColor(Self.suspiciousColor.cgColor)
            context.setLineWidth(2)
            context.stroke(placement.frame.insetBy(dx: 1, dy: 1))
        }
        context.restoreGState()
    }

    /// The outline around the newest scroll's segments.
    static func newestFrame(_ layout: Layout) -> CGRect? {
        let newest = layout.segments.filter(\.isNewest).map(\.frame)
        guard let first = newest.first else { return nil }
        return newest.dropFirst().reduce(first) { $0.union($1) }
    }
}
