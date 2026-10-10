import AppKit
import SwiftUI

/// Keeps a document smaller than the visible area in its middle instead of its corner.
final class ScreenshotCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// The long image editor on one display: the image fitted to the width in a scroll view that
/// zooms (⌘+ / ⌘− / ⌘0), a minimap beside it that jumps on click, the size and zoom above it and
/// the annotation toolbar below it.
@MainActor
final class ScreenshotLongImageEditorView: NSView {
    static let sideMargin: CGFloat = 48
    static let topMargin: CGFloat = 28
    static let gap: CGFloat = 12
    static let infoHeight: CGFloat = 20
    /// Room for the toolbar's two rows under the image.
    static let toolbarRoom: CGFloat = 96
    static let maxMagnification: CGFloat = 4
    static let zoomFactor: CGFloat = 1.25

    let canvas: ScreenshotLongImageCanvas
    let scrollView = NSScrollView()
    let minimap = ScreenshotLongImageMinimapView()
    private let info = NSTextField(labelWithString: "")
    private(set) var toolbar: ScreenshotToolbarHostingView?
    private var hasFitted = false

    init(frame: CGRect, canvas: ScreenshotLongImageCanvas) {
        self.canvas = canvas
        super.init(frame: frame)
        let clip = ScreenshotCenteringClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = Self.maxMagnification
        addSubview(scrollView)
        minimap.setImage(canvas.image, pointSize: canvas.bounds.size)
        minimap.onJump = { [weak self] point in self?.show(centeredAt: point) }
        addSubview(minimap)
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        info.textColor = NSColor.white.withAlphaComponent(0.8)
        addSubview(info)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        canvas.onChange = { [weak self] in self?.refreshToolbar() }
        refreshToolbar()
        layOut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        dirtyRect.fill()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layOut()
    }

    // MARK: Layout

    /// Where the scroll view goes: under the size line, left of the minimap, above the toolbar.
    static func scrollFrame(in bounds: CGRect) -> CGRect {
        let top = bounds.minY + topMargin + infoHeight + 6
        let bottom = bounds.maxY - toolbarRoom
        let width = bounds.width - sideMargin * 2 - ScreenshotLongImageMinimapView.width - gap
        return CGRect(x: bounds.minX + sideMargin, y: top, width: max(width, 1), height: max(bottom - top, 1))
    }

    private func layOut() {
        let frame = Self.scrollFrame(in: bounds)
        scrollView.frame = frame
        minimap.frame = CGRect(x: frame.maxX + Self.gap, y: frame.minY, width: ScreenshotLongImageMinimapView.width,
                               height: frame.height)
        info.frame = CGRect(x: frame.minX, y: bounds.minY + Self.topMargin, width: frame.width, height: Self.infoHeight)
        if !hasFitted, frame.width > 1 {
            hasFitted = true
            zoom(0)
            canvas.scroll(.zero)
        }
        placeToolbar()
        visibleAreaChanged()
    }

    // MARK: Zoom

    /// As wide as the visible area, but never enlarged.
    var fittingMagnification: CGFloat {
        let width = scrollView.contentSize.width
        guard canvas.bounds.width > 0, width > 0 else { return 1 }
        return min(1, width / canvas.bounds.width)
    }

    /// Small enough to see the whole image, but not below 5%.
    var minimumMagnification: CGFloat {
        let size = scrollView.contentSize
        guard canvas.bounds.height > 0, size.height > 0 else { return fittingMagnification }
        return max(0.05, min(fittingMagnification, size.height / canvas.bounds.height))
    }

    /// One step in (positive) or out (negative), or back to the width (zero), around the middle of the view.
    func zoom(_ step: Int) {
        scrollView.minMagnification = minimumMagnification
        let target = step == 0 ? fittingMagnification
            : scrollView.magnification * pow(Self.zoomFactor, CGFloat(step))
        let clamped = min(max(target, scrollView.minMagnification), Self.maxMagnification)
        let visible = canvas.visibleRect
        let center = visible.isEmpty ? CGPoint(x: canvas.bounds.midX, y: 0)
            : CGPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        visibleAreaChanged()
    }

    /// Scrolls so `point` (in the image's points) is in the middle of the view.
    func show(centeredAt point: CGPoint) {
        let visible = canvas.visibleRect
        canvas.scroll(CGPoint(x: point.x - visible.width / 2, y: point.y - visible.height / 2))
        visibleAreaChanged()
    }

    @objc private func visibleAreaChanged() {
        minimap.viewport = canvas.visibleRect
        let pixels = "\(canvas.image.width) × \(canvas.image.height) px"
        info.stringValue = "\(pixels) · \(Int((scrollView.magnification * 100).rounded()))%"
    }

    // MARK: Toolbar

    private func refreshToolbar() {
        let state = canvas.toolbarState
        let host: ScreenshotToolbarHostingView
        if let toolbar {
            host = toolbar
            if host.shownState != state { host.rootView = toolbarView(state) }
        } else {
            host = ScreenshotToolbarHostingView(rootView: toolbarView(state))
            host.hitInset = ScreenshotOverlayView.toolbarShadowInset
            addSubview(host)
            toolbar = host
        }
        host.shownState = state
        placeToolbar()
    }

    private func placeToolbar() {
        guard let toolbar else { return }
        let size = toolbar.fittingSize
        let inset = ScreenshotOverlayView.toolbarShadowInset
        let top = Self.scrollFrame(in: bounds).maxY + Self.gap - inset
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: top, width: size.width, height: size.height)
    }

    private func toolbarView(_ state: ScreenshotEditorToolbarModel.State) -> AnyView {
        AnyView(ScreenshotEditorToolbar(state: state) { [weak self] in self?.canvas.perform($0) }
            .padding(ScreenshotOverlayView.toolbarShadowInset))
    }

    func releaseImage() {
        canvas.releaseImage()
        minimap.releaseImage()
        NotificationCenter.default.removeObserver(self)
    }
}

/// The long image editor that `ScreenshotCoordinator` opens after a scrolling capture.
@MainActor
protocol ScreenshotLongImagePresenting: AnyObject {
    /// - Parameters:
    ///   - image: the long image as a display whose frame is the image in its own points.
    ///   - screen: where to show the editor, a display frame in global Quartz points.
    func present(_ image: ScreenSnapshot.Display, on screen: CGRect,
                 onEvent: @escaping (ScreenshotOverlayEvent) -> Void)
    func dismiss()
}

@MainActor
final class ScreenshotLongImageEditorController: ScreenshotLongImagePresenting {
    private(set) var panel: ScreenshotFloatingPanel?
    private(set) var editorView: ScreenshotLongImageEditorView?
    private let primaryDisplayHeight: () -> CGFloat
    private let textMeasurer: (any ScreenshotTextHeightMeasuring)?

    init(primaryDisplayHeight: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 },
         textMeasurer: (any ScreenshotTextHeightMeasuring)? = nil) {
        self.primaryDisplayHeight = primaryDisplayHeight
        self.textMeasurer = textMeasurer
    }

    var isPresented: Bool { panel != nil }

    func present(_ image: ScreenSnapshot.Display, on screen: CGRect,
                 onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
        dismiss()
        let canvas = ScreenshotLongImageCanvas(image: image.image, scale: image.scale, textMeasurer: textMeasurer)
        let view = ScreenshotLongImageEditorView(frame: CGRect(origin: .zero, size: screen.size), canvas: canvas)
        canvas.onEvent = { [weak view] event in
            switch event {
            case let .finish(action, annotations):
                onEvent(.finish(action, displayID: image.id, rect: image.frame, annotations: annotations))
            case .cancelled:
                onEvent(.cancelled)
            case let .zoom(step):
                view?.zoom(step)
            }
        }
        let panel = ScreenshotFloatingPanel(
            frame: ScreenCaptureGeometry.flipped(screen, primaryDisplayHeight: primaryDisplayHeight()),
            becomesKey: true
        )
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(canvas)
        self.panel = panel
        editorView = view
    }

    func dismiss() {
        editorView?.releaseImage()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        editorView = nil
    }
}
