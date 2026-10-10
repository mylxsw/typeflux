import AppKit

/// A borderless panel above the menu bar and full-screen apps, on every Space.
final class ScreenshotOverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows one overlay panel per frozen display. A region stays on one display: pressing
/// on another one moves the selection there. Keys act on the display that has the selection.
@MainActor
final class ScreenshotOverlayController: ScreenshotOverlayPresenting {
    private(set) var panels: [ScreenshotOverlayPanel] = []
    private(set) var views: [ScreenshotOverlayView] = []
    private var onEvent: ((ScreenshotOverlayEvent) -> Void)?
    private let primaryDisplayHeight: () -> CGFloat
    /// The pointer in global Quartz points.
    private let pointerLocation: () -> CGPoint

    init(primaryDisplayHeight: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 },
         pointerLocation: @escaping () -> CGPoint = {
             CGEvent(source: nil)?.location ?? .zero
         }) {
        self.primaryDisplayHeight = primaryDisplayHeight
        self.pointerLocation = pointerLocation
    }

    var isPresented: Bool { !panels.isEmpty }

    func present(_ snapshot: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
        dismiss()
        self.onEvent = onEvent
        let primaryHeight = primaryDisplayHeight()
        for display in snapshot.displays {
            let view = ScreenshotOverlayView(display: display, windows: snapshot.windows)
            view.onActivate = { [weak self] view in self?.activate(view) }
            view.onEvent = { [weak self] view, event in self?.forward(event, from: view) }
            let panel = ScreenshotOverlayPanel(
                frame: ScreenCaptureGeometry.flipped(display.frame, primaryDisplayHeight: primaryHeight)
            )
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        if let view = viewUnderPointer() {
            focus(view)
            // Show the loupe at once, before the pointer moves.
            let pointer = pointerLocation()
            view.pointerMoved(to: CGPoint(x: pointer.x - view.display.frame.minX,
                                          y: pointer.y - view.display.frame.minY))
        }
    }

    func selectFullScreen() {
        guard let view = views.first(where: { $0.selection.rect != nil }) ?? viewUnderPointer() else { return }
        view.selectAll()
    }

    func dismiss() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        views.forEach { $0.releaseImage() }
        panels = []
        views = []
        onEvent = nil
    }

    /// The view whose display holds the pointer, or the first one.
    func viewUnderPointer() -> ScreenshotOverlayView? {
        let pointer = pointerLocation()
        return views.first { $0.display.frame.contains(pointer) } ?? views.first
    }

    private func activate(_ view: ScreenshotOverlayView) {
        for other in views where other !== view && other.selection.rect != nil {
            other.clearSelection()
        }
        focus(view)
    }

    private func focus(_ view: ScreenshotOverlayView) {
        guard let panel = view.window else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    private func forward(_ event: ScreenshotOverlayView.LocalEvent, from view: ScreenshotOverlayView) {
        let origin = view.display.frame.origin
        switch event {
        case .committed:
            onEvent?(.committed)
        case let .finish(action, rect):
            onEvent?(.finish(action, displayID: view.display.id, rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
        case let .colorPicked(hex):
            onEvent?(.colorPicked(hex))
        case .cancelled:
            onEvent?(.cancelled)
        }
    }
}
