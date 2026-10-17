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

    var onHide: (() -> Void)?
    override func orderOut(_ sender: Any?) { onHide?(); super.orderOut(sender) }
    override func close() { onHide?(); super.close() }

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
    private let modifierFlags: () -> NSEvent.ModifierFlags
    /// Sizes mosaics to the text under them.
    private let textMeasurer: (any ScreenshotTextHeightMeasuring)?
    /// Finds sensitive text to suggest mosaics for.
    private let sensitiveScanner: (any ScreenshotSensitiveInfoScanning)?
    /// Each tool's style, shared by every display and kept for the next screenshot.
    private let toolStyles: ScreenshotToolStyleStore

    init(primaryDisplayHeight: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 },
         pointerLocation: @escaping () -> CGPoint = {
             CGEvent(source: nil)?.location ?? .zero
         },
         modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         textMeasurer: (any ScreenshotTextHeightMeasuring)? = nil,
         sensitiveScanner: (any ScreenshotSensitiveInfoScanning)? = nil,
         toolStyles: ScreenshotToolStyleStore = ScreenshotToolStyleStore()) {
        self.primaryDisplayHeight = primaryDisplayHeight
        self.pointerLocation = pointerLocation
        self.modifierFlags = modifierFlags
        self.textMeasurer = textMeasurer
        self.sensitiveScanner = sensitiveScanner
        self.toolStyles = toolStyles
    }

    var isPresented: Bool { !panels.isEmpty }

    func present(_ snapshot: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
        dismiss()
        self.onEvent = onEvent
        let primaryHeight = primaryDisplayHeight()
        let initialModifierFlags = modifierFlags()
        for display in snapshot.displays {
            let view = ScreenshotOverlayView(display: display, windows: snapshot.windows,
                                             initialModifierFlags: initialModifierFlags, textMeasurer: textMeasurer,
                                             sensitiveScanner: sensitiveScanner, toolStyles: toolStyles)
            view.onActivate = { [weak self] view in self?.activate(view) ?? true }
            view.onEvent = { [weak self] view, event in self?.forward(event, from: view) }
            let panel = ScreenshotOverlayPanel(
                frame: ScreenCaptureGeometry.flipped(display.frame, primaryDisplayHeight: primaryHeight)
            )
            panel.onHide = { [weak view] in view?.releaseImage() }
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

    func startScrollCapture() {
        views.first { $0.selection.rect != nil }?.startScrollCapture()
    }

    func finish(_ action: ScreenshotOutputAction) {
        views.first { $0.selection.rect != nil }?.finish(action)
    }

    func backgroundRemovedImage(displayID: CGDirectDisplayID, rect: CGRect) -> CGImage? {
        guard let view = views.first(where: { $0.display.id == displayID }),
              view.backgroundRemoval.region?.offsetBy(dx: view.display.frame.minX, dy: view.display.frame.minY) == rect
        else { return nil }
        return view.backgroundRemoval.image
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

    /// - Returns: false while another display is being marked up; it keeps its region.
    private func activate(_ view: ScreenshotOverlayView) -> Bool {
        if views.contains(where: { $0 !== view && $0.isAnnotating }) { return false }
        for other in views where other !== view && other.selection.rect != nil {
            other.clearSelection()
        }
        view.adoptStoredStyles()
        focus(view)
        return true
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
        case let .finish(action, rect, annotations):
            onEvent?(.finish(action, displayID: view.display.id, rect: rect.offsetBy(dx: origin.x, dy: origin.y),
                             annotations: annotations.map { $0.offsetBy(dx: origin.x, dy: origin.y) }))
        case let .scroll(rect):
            onEvent?(.scroll(displayID: view.display.id, rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
        case let .colorPicked(hex):
            onEvent?(.colorPicked(hex))
        case .cancelled:
            onEvent?(.cancelled)
        }
    }
}
