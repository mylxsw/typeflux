import AppKit

/// A plain fill; for the dimmed panels around the region.
final class ScrollCaptureFillView: NSView {
    private let color: NSColor

    init(frame: CGRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// The region's outline; lets every event through to the app under it.
final class ScrollCaptureOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: ScrollCaptureLayout.outlineWidth / 2,
                                                     dy: ScrollCaptureLayout.outlineWidth / 2))
        NSColor.black.withAlphaComponent(0.65).setStroke()
        path.lineWidth = ScrollCaptureLayout.outlineWidth + 2
        path.stroke()
        ScreenshotOverlayChromeView.frameColor.setStroke()
        path.lineWidth = ScrollCaptureLayout.outlineWidth
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The scrolling capture's panels: four dimmed panels around the region, its outline, the bar and
/// the preview strip. The region itself stays uncovered, so the wheel reaches the app under it.
@MainActor
final class ScrollCaptureOverlayController: ScrollCapturePresenting {
    static let dimAlpha: CGFloat = 0.42

    private(set) var dimPanels: [ScreenshotFloatingPanel] = []
    private(set) var outlinePanel: ScreenshotFloatingPanel?
    private(set) var barPanel: ScreenshotFloatingPanel?
    private(set) var previewPanel: ScreenshotFloatingPanel?
    private(set) var barView: ScrollCaptureBarView?
    private(set) var previewView: ScrollCapturePreviewView?
    private var region: ScrollCaptureRegion?
    private let primaryDisplayHeight: () -> CGFloat

    init(primaryDisplayHeight: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 }) {
        self.primaryDisplayHeight = primaryDisplayHeight
    }

    var isPresented: Bool { barPanel != nil }

    func present(_ region: ScrollCaptureRegion, actions: ScrollCaptureActions) {
        dismiss()
        self.region = region
        for rect in ScrollCaptureLayout.dimRects(around: region.rect, in: region.displayFrame) {
            let panel = makePanel(rect)
            panel.contentView = ScrollCaptureFillView(frame: CGRect(origin: .zero, size: rect.size),
                                                      color: NSColor.black.withAlphaComponent(Self.dimAlpha))
            dimPanels.append(panel)
        }
        let outlineRect = ScrollCaptureLayout.outlineRect(around: region.rect)
        let outline = makePanel(outlineRect)
        outline.ignoresMouseEvents = true
        outline.contentView = ScrollCaptureOutlineView(frame: CGRect(origin: .zero, size: outlineRect.size))
        outlinePanel = outline

        let previewRect = ScrollCaptureLayout.previewFrame(region: region.rect, display: region.displayFrame)
        let preview = makePanel(previewRect)
        preview.ignoresMouseEvents = true
        let previewView = ScrollCapturePreviewView(frame: CGRect(origin: .zero, size: previewRect.size))
        preview.contentView = previewView
        previewPanel = preview
        self.previewView = previewView

        let bar = ScrollCaptureBarView(frame: .zero)
        bar.actions = actions
        let barPanel = makePanel(.zero, becomesKey: true)
        barPanel.contentView = bar
        self.barPanel = barPanel
        barView = bar
        layOutBar(for: ScrollCaptureViewState())

        for panel in dimPanels + [outline, preview, barPanel] {
            panel.onHide = actions.cancel
            panel.orderFrontRegardless()
        }
        barPanel.makeKey()
        barPanel.makeFirstResponder(bar)
    }

    func update(_ state: ScrollCaptureViewState, preview: ScrollCapturePreview) {
        guard region != nil else { return }
        layOutBar(for: state)
        previewView?.preview = preview
        // A click in the app being captured takes the keys away; ␣ ⌫ esc ↩ belong to the bar until the end.
        if let barPanel, let barView, !barPanel.isKeyWindow {
            barPanel.makeKey()
            barPanel.makeFirstResponder(barView)
        }
    }

    func dismiss() {
        let panels = dimPanels + [outlinePanel, previewPanel, barPanel].compactMap { $0 }
        panels.forEach { $0.onHide = nil }
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        dimPanels = []
        outlinePanel = nil
        previewPanel = nil
        barPanel = nil
        barView = nil
        previewView = nil
        region = nil
    }

    private func layOutBar(for state: ScrollCaptureViewState) {
        guard let region, let barView, let barPanel else { return }
        let size = barView.show(state)
        let frame = ScrollCaptureLayout.barFrame(size: size, region: region.rect, display: region.displayFrame)
        barPanel.setFrame(appKitFrame(frame), display: true)
    }

    private func makePanel(_ rect: CGRect, becomesKey: Bool = false) -> ScreenshotFloatingPanel {
        ScreenshotFloatingPanel(frame: appKitFrame(rect), becomesKey: becomesKey)
    }

    private func appKitFrame(_ rect: CGRect) -> CGRect {
        ScreenCaptureGeometry.flipped(rect, primaryDisplayHeight: primaryDisplayHeight())
    }
}
