import AppKit
import QuartzCore

/// One display's frozen image with the framing interface over it. The image sits in a
/// layer as it is, never redrawn; the outline, handles, labels and loupe are drawn by
/// a transparent view above it. All geometry lives in `ScreenshotSelection`.
@MainActor
final class ScreenshotOverlayView: NSView {
    enum Key {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let keyA: UInt16 = 0
        static let keyS: UInt16 = 1
        static let keyC: UInt16 = 8
        static let arrowLeft: UInt16 = 123
        static let arrowRight: UInt16 = 124
        static let arrowDown: UInt16 = 125
        static let arrowUp: UInt16 = 126
    }

    let display: ScreenSnapshot.Display
    private(set) var selection: ScreenshotSelection
    /// Space is held: dragging moves the region instead of growing it.
    private(set) var spaceHeld = false
    private var shiftHeld = false

    /// The user pressed on this display; other displays drop their selection.
    var onActivate: ((ScreenshotOverlayView) -> Void)?
    /// Events in this display's own coordinates; the controller converts them.
    var onEvent: ((ScreenshotOverlayView, LocalEvent) -> Void)?

    enum LocalEvent: Equatable {
        case committed
        case finish(ScreenshotOutputAction, CGRect)
        case colorPicked(String)
        case cancelled
    }

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let chrome: ScreenshotOverlayChromeView

    init(display: ScreenSnapshot.Display, windows: [ScreenSnapshot.Window]) {
        self.display = display
        selection = ScreenshotSelection(displayFrame: display.frame, scale: display.scale, windows: windows)
        chrome = ScreenshotOverlayChromeView(frame: CGRect(origin: .zero, size: display.frame.size))
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contents = display.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimLayer.frame = bounds
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(dimLayer)
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Lets go of the frozen image as soon as the overlay closes.
    func releaseImage() {
        imageLayer.contents = nil
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: location(of: event)) }
    override func mouseExited(with event: NSEvent) {
        selection.pointerExited()
        refresh()
    }

    override func mouseDown(with event: NSEvent) { mouseDown(at: location(of: event), clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { mouseDragged(to: location(of: event)) }
    override func mouseUp(with event: NSEvent) { mouseUp(at: location(of: event)) }
    override func rightMouseDown(with event: NSEvent) { onEvent?(self, .cancelled) }

    func pointerMoved(to point: CGPoint) {
        selection.pointerMoved(to: point)
        updateCursor(at: point)
        refresh()
    }

    func mouseDown(at point: CGPoint, clickCount: Int) {
        onActivate?(self)
        if selection.mouseDown(at: point, clickCount: clickCount) == .confirmed, let rect = selection.rect {
            onEvent?(self, .finish(.copy, rect))
            return
        }
        refresh()
    }

    func mouseDragged(to point: CGPoint) {
        _ = selection.mouseDragged(to: point, movesSelection: spaceHeld)
        refresh()
    }

    func mouseUp(at point: CGPoint) {
        if selection.mouseUp(at: point) == .committed { onEvent?(self, .committed) }
        updateCursor(at: point)
        refresh()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        handleKeyUp(event.keyCode)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        return handleKeyDown(event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(event.modifierFlags)
    }

    /// - Returns: whether the key meant something here.
    @discardableResult
    func handleKeyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        let command = modifiers.contains(.command)
        if let offset = Self.nudgeOffset(for: keyCode, modifiers: modifiers) {
            nudge(offset)
            return true
        }
        switch keyCode {
        case Key.escape:
            onEvent?(self, .cancelled)
        case Key.returnKey, Key.enter:
            finish(.copy)
        case Key.keyC where command:
            finish(.copy)
        case Key.keyS where command:
            finish(.save)
        case Key.keyA where command:
            selectAll()
        case Key.space:
            spaceHeld = true
        default:
            return false
        }
        return true
    }

    /// Arrow keys move the region one point, or ten with ⇧.
    static func nudgeOffset(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CGSize? {
        let step = modifiers.contains(.shift) ? ScreenshotSelection.largeNudgeStep : ScreenshotSelection.nudgeStep
        switch keyCode {
        case Key.arrowLeft: return CGSize(width: -step, height: 0)
        case Key.arrowRight: return CGSize(width: step, height: 0)
        case Key.arrowUp: return CGSize(width: 0, height: -step)
        case Key.arrowDown: return CGSize(width: 0, height: step)
        default: return nil
        }
    }

    func handleKeyUp(_ keyCode: UInt16) {
        if keyCode == Key.space { spaceHeld = false }
    }

    /// ⇧ pressed while the loupe shows copies the color under the pointer.
    func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let shift = flags.contains(.shift)
        defer { shiftHeld = shift }
        guard shift, !shiftHeld, showsLoupe, let hex = pickedColor?.hex else { return }
        onEvent?(self, .colorPicked(hex))
    }

    /// ⌘A, or the shortcut pressed again: the whole display.
    func selectAll() {
        onActivate?(self)
        _ = selection.selectAll()
        onEvent?(self, .committed)
        refresh()
    }

    /// Another display took the selection.
    func clearSelection() {
        selection.clear()
        refresh()
    }

    private func nudge(_ offset: CGSize) {
        if selection.nudge(by: offset) == .changed { refresh() }
    }

    private func finish(_ action: ScreenshotOutputAction) {
        guard let rect = selection.rect, !selection.isDragging else { return }
        onEvent?(self, .finish(action, rect))
    }

    // MARK: Drawing

    /// The loupe and guides help aim, so they show until a region is chosen and while one is drawn.
    var showsLoupe: Bool {
        selection.pointer != nil && (selection.rect == nil || selection.isDragging)
    }

    var pickedColor: ScreenshotMagnifier.RGB? {
        guard let pointer = selection.pointer else { return nil }
        let pixel = ScreenshotMagnifier.pixel(at: pointer, displaySize: bounds.size, imageSize: display.pixelSize)
        return ScreenshotMagnifier.color(of: display.image, at: pixel)
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let highlighted = selection.highlighted { path.addRect(highlighted) }
        dimLayer.path = path
        CATransaction.commit()
        chrome.model = ScreenshotOverlayChromeView.Model(
            selection: selection.rect,
            hovered: selection.rect == nil ? selection.hovered : nil,
            handles: selection.rect != nil && !selection.isDragging,
            sizeLabel: selection.sizeLabel,
            pointer: showsLoupe ? selection.pointer : nil,
            loupe: showsLoupe ? loupe() : nil,
            hint: selection.rect != nil && !selection.isDragging ? L("screenshot.overlay.hint") : nil
        )
    }

    private func loupe() -> ScreenshotOverlayChromeView.Loupe? {
        guard let pointer = selection.pointer else { return nil }
        let pixel = ScreenshotMagnifier.pixel(at: pointer, displaySize: bounds.size, imageSize: display.pixelSize)
        let sample = ScreenshotMagnifier.sampleRect(around: pixel)
        let imageBounds = CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height)
        let visible = sample.intersection(imageBounds)
        let image = visible.isNull ? nil : display.image.cropping(to: visible)
        // Where the visible part of the sample sits in the full 11 × 9 grid.
        let offset = CGPoint(x: visible.isNull ? 0 : visible.minX - sample.minX,
                             y: visible.isNull ? 0 : visible.minY - sample.minY)
        return .init(frame: ScreenshotMagnifier.frame(for: pointer, in: bounds), image: image, imageOffset: offset,
                     imageSize: visible.isNull ? .zero : visible.size,
                     coordinates: "\(Int(pointer.x)), \(Int(pointer.y))", color: pickedColor?.hex ?? "")
    }

    private func updateCursor(at point: CGPoint) {
        let cursor: NSCursor = switch selection.isDragging ? .outside : selection.hit(at: point) {
        case let .handle(handle):
            switch handle {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        case .inside: .openHand
        case .outside: .crosshair
        }
        cursor.set()
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
