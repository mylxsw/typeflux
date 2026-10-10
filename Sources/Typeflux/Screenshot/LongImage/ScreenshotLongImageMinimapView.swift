import AppKit

/// The whole long image in miniature beside the editor, with the visible part outlined.
/// A click or a drag shows that part of the image.
@MainActor
final class ScreenshotLongImageMinimapView: NSView {
    static let width: CGFloat = 72
    static let inset: CGFloat = 6
    /// The thumbnail is made this many pixels wide per point of the strip, for a sharp picture.
    static let thumbnailScale: CGFloat = 2

    private(set) var thumbnail: CGImage?
    /// The image's size in points.
    private(set) var imageSize: CGSize = .zero
    /// The visible part, in the image's points.
    var viewport: CGRect = .zero {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// Asks to show the image centered on this point, in its points.
    var onJump: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: CGImage, pointSize: CGSize) {
        imageSize = pointSize
        let width = Int(Self.width * Self.thumbnailScale)
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(max(image.width, 1))).rounded()))
        thumbnail = ScreenCaptureGeometry.resized(image, to: ScreenPixelSize(width: width, height: height))
        needsDisplay = true
    }

    func releaseImage() {
        thumbnail = nil
    }

    /// Where the image sits in the strip: as wide as it fits, and no taller than the strip.
    static func imageFrame(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.minY, width: size.width, height: size.height)
    }

    /// A point in the strip, as a point in the image.
    static func imagePoint(for point: CGPoint, imageSize: CGSize, in bounds: CGRect) -> CGPoint? {
        let frame = imageFrame(imageSize: imageSize, in: bounds)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let clampedX = min(max(point.x, frame.minX), frame.maxX)
        let clampedY = min(max(point.y, frame.minY), frame.maxY)
        return CGPoint(x: (clampedX - frame.minX) / frame.width * imageSize.width,
                       y: (clampedY - frame.minY) / frame.height * imageSize.height)
    }

    /// The visible part, outlined in the strip.
    static func viewportFrame(visible: CGRect, imageSize: CGSize, in bounds: CGRect) -> CGRect {
        let frame = imageFrame(imageSize: imageSize, in: bounds)
        guard frame.width > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let clipped = visible.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull else { return .zero }
        let scaleX = frame.width / imageSize.width, scaleY = frame.height / imageSize.height
        return CGRect(x: frame.minX + clipped.minX * scaleX, y: frame.minY + clipped.minY * scaleY,
                      width: clipped.width * scaleX, height: clipped.height * scaleY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.45).setFill()
        card.fill()
        let frame = Self.imageFrame(imageSize: imageSize, in: bounds)
        if let thumbnail {
            context.interpolationQuality = .high
            ScreenshotRenderer.drawImage(thumbnail, in: frame, context: context)
        }
        let viewport = Self.viewportFrame(visible: viewport, imageSize: imageSize, in: bounds)
        guard !viewport.isEmpty else { return }
        context.setFillColor(ScreenshotOverlayChromeView.accent.withAlphaComponent(0.16).cgColor)
        context.fill(viewport)
        context.setStrokeColor(ScreenshotOverlayChromeView.accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(viewport.insetBy(dx: 0.75, dy: 0.75))
    }

    override func mouseDown(with event: NSEvent) { jump(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { jump(to: convert(event.locationInWindow, from: nil)) }

    func jump(to point: CGPoint) {
        guard let target = Self.imagePoint(for: point, imageSize: imageSize, in: bounds) else { return }
        onJump?(target)
    }
}
