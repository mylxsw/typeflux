import AppKit

/// Draws the annotations over the frozen display, clipped to the chosen region, with the
/// same `ScreenshotRenderer` code the export uses. The frozen image itself stays in the
/// overlay's layer; this view only adds mosaics and marks on top. It only draws; the
/// overlay view under it takes the input.
@MainActor
final class ScreenshotAnnotationCanvasView: NSView {
    struct Model: Equatable {
        var crop: CGRect?
        var annotations: [ScreenshotAnnotation] = []
        /// The selected annotation's frame, outlined with a dashed line.
        var selection: CGRect?
        var handles: [CGPoint] = []
    }

    private struct PatchKey: Equatable {
        var mosaic: ScreenshotMosaic
        var color: ScreenshotAnnotationStyle.Color
        var crop: CGRect
    }

    var model = Model() {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    /// The frozen display, read by mosaics.
    private var source: CGImage?
    /// Mosaic pixels by annotation, kept while the mosaic and the region stay the same.
    private var patches: [UUID: (key: PatchKey, patch: ScreenshotRenderer.MosaicPatch?)] = [:]
    private(set) var patchComputations = 0

    init(frame: CGRect, source: CGImage) {
        self.source = source
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func releaseImage() {
        source = nil
        patches = [:]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawContents(in: context)
    }

    /// Everything this view shows, into a context in the display's points with y growing downward.
    func drawContents(in context: CGContext) {
        let ids = Set(model.annotations.map(\.id))
        patches = patches.filter { ids.contains($0.key) }
        guard let crop = model.crop else { return }
        context.saveGState()
        context.clip(to: crop)
        for annotation in model.annotations {
            guard let mosaic = annotation.mosaic,
                  let patch = patch(for: annotation.id, mosaic: mosaic, color: annotation.style.color, crop: crop)
            else { continue }
            ScreenshotRenderer.drawImage(patch.image, in: patch.rect, context: context)
        }
        ScreenshotRenderer.draw(model.annotations, in: context)
        context.restoreGState()
        if let selection = model.selection { drawSelection(selection, in: context) }
    }

    private func patch(for id: UUID, mosaic: ScreenshotMosaic, color: ScreenshotAnnotationStyle.Color,
                       crop: CGRect) -> ScreenshotRenderer.MosaicPatch? {
        let key = PatchKey(mosaic: mosaic, color: color, crop: crop)
        if let cached = patches[id], cached.key == key { return cached.patch }
        guard let source else { return nil }
        patchComputations += 1
        let patch = ScreenshotRenderer.mosaicPatch(for: mosaic, color: color, source: source,
                                                   sourceFrame: CGRect(origin: .zero, size: bounds.size), crop: crop)
        patches[id] = (key, patch)
        return patch
    }

    private func drawSelection(_ frame: CGRect, in context: CGContext) {
        context.saveGState()
        let outline = frame.insetBy(dx: -4, dy: -4)
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.stroke(outline)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(outline)
        context.restoreGState()
        let size = ScreenshotOverlayChromeView.handleSize
        for handle in model.handles {
            let rect = CGRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.setStrokeColor(ScreenshotOverlayChromeView.accent.cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)
        }
    }
}
