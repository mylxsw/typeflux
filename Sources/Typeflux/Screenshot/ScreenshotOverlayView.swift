// swiftlint:disable file_length
import AppKit
import QuartzCore
import SwiftUI

/// One display's frozen image with the framing and editing interface over it. The image
/// sits in a layer as it is, never redrawn; annotations are drawn by a canvas view clipped
/// to the region, and the outline, handles, labels and loupe by a transparent view above
/// it. Framing geometry lives in `ScreenshotSelection`, editing in `ScreenshotAnnotationEditor`.
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
        static let keyZ: UInt16 = 6
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let arrowLeft: UInt16 = 123
        static let arrowRight: UInt16 = 124
        static let arrowDown: UInt16 = 125
        static let arrowUp: UInt16 = 126
    }

    let display: ScreenSnapshot.Display
    private(set) var selection: ScreenshotSelection
    private(set) var editor = ScreenshotAnnotationEditor()
    /// Space is held: dragging moves the region instead of growing it.
    private(set) var spaceHeld = false
    private var shiftHeld = false

    /// The user pressed on this display; other displays drop their selection. Returns false
    /// when another display is being marked up, and the press is ignored so no work is lost.
    var onActivate: ((ScreenshotOverlayView) -> Bool)?
    /// Events in this display's own coordinates; the controller converts them.
    var onEvent: ((ScreenshotOverlayView, LocalEvent) -> Void)?

    enum LocalEvent: Equatable {
        case committed
        /// Use the region with these annotations, all in this display's points.
        case finish(ScreenshotOutputAction, CGRect, [ScreenshotAnnotation] = [])
        case colorPicked(String)
        case cancelled
    }

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let canvas: ScreenshotAnnotationCanvasView
    private let chrome: ScreenshotOverlayChromeView
    let toolbarModel = ScreenshotEditorToolbarModel()
    private(set) var toolbar: ScreenshotToolbarHostingView?
    /// The field for typing a text annotation, while one is typed.
    private(set) var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private let textMeasurer: (any ScreenshotTextHeightMeasuring)?

    /// Room around the toolbar for its shadow.
    static let toolbarShadowInset: CGFloat = 18

    init(display: ScreenSnapshot.Display, windows: [ScreenSnapshot.Window],
         textMeasurer: (any ScreenshotTextHeightMeasuring)? = nil) {
        self.display = display
        self.textMeasurer = textMeasurer
        selection = ScreenshotSelection(displayFrame: display.frame, scale: display.scale, windows: windows)
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        canvas = ScreenshotAnnotationCanvasView(frame: bounds, source: display.image)
        chrome = ScreenshotOverlayChromeView(frame: bounds)
        super.init(frame: bounds)
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
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        editor.measureTextHeight = { [weak self] mosaic in self?.measureTextHeight(under: mosaic) }
        toolbarModel.onAction = { [weak self] action in self?.perform(action) }
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
        canvas.releaseImage()
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: location(of: event)) }
    override func mouseExited(with event: NSEvent) {
        selection.pointerExited()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDown(at: location(of: event), clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDragged(to: location(of: event), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        mouseUp(at: location(of: event), shift: event.modifierFlags.contains(.shift))
    }
    override func rightMouseDown(with event: NSEvent) { onEvent?(self, .cancelled) }

    func pointerMoved(to point: CGPoint) {
        selection.pointerMoved(to: point)
        updateCursor(at: point)
        refresh()
    }

    func mouseDown(at point: CGPoint, clickCount: Int, shift: Bool = false) {
        guard onActivate?(self) ?? true else { return }
        endTextEditing()
        if let crop = selection.rect, !selection.isDragging {
            let cropHit = selection.hit(at: point)
            switch editor.mouseDown(at: point, clickCount: clickCount, crop: crop, cropHit: cropHit) {
            case .handled:
                refresh()
                return
            case let .beginText(origin):
                beginTextEditing(at: origin, text: "", fontSize: editor.style.fontSize, color: editor.style.color)
                refresh()
                return
            case let .editText(id):
                if let annotation = editor.document.annotation(id: id),
                   case let .text(origin, text, fontSize) = annotation.kind {
                    beginTextEditing(at: origin, text: text, fontSize: fontSize, color: annotation.style.color)
                }
                refresh()
                return
            case .ignored:
                // Once marking has started, a press outside keeps the region instead of framing a new one.
                if cropHit == .outside, isAnnotating {
                    refresh()
                    return
                }
            }
        }
        if selection.mouseDown(at: point, clickCount: clickCount) == .confirmed, let rect = selection.rect {
            onEvent?(self, .finish(.copy, rect, editor.document.annotations))
            return
        }
        refresh()
    }

    func mouseDragged(to point: CGPoint, shift: Bool = false) {
        if editor.isDragging {
            editor.mouseDragged(to: point, shift: shift)
        } else {
            _ = selection.mouseDragged(to: point, movesSelection: spaceHeld)
        }
        refresh()
    }

    func mouseUp(at point: CGPoint, shift: Bool = false) {
        if editor.isDragging {
            editor.mouseUp(at: point, shift: shift)
        } else if selection.mouseUp(at: point) == .committed {
            onEvent?(self, .committed)
        }
        updateCursor(at: point)
        refresh()
    }

    /// A tool is picked or something is marked: the region stays put.
    var isAnnotating: Bool {
        editor.tool != nil || !editor.document.isEmpty
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
        // While typing, ⌘C, ⌘A, ⌘Z and the like belong to the text field.
        guard event.type == .keyDown, event.modifierFlags.contains(.command), textField == nil else { return false }
        return handleKeyDown(event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(event.modifierFlags)
    }

    /// - Returns: whether the key meant something here.
    @discardableResult
    func handleKeyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        let command = modifiers.contains(.command)
        if handleEditingKey(keyCode, modifiers: modifiers) { return true }
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

    /// Tool letters, undo and redo, delete, and arrows on a selected annotation; only once a region is chosen.
    private func handleEditingKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard selection.rect != nil, !selection.isDragging else { return false }
        let command = modifiers.contains(.command)
        let handled: Bool
        if keyCode == Key.keyZ, command {
            if modifiers.contains(.shift) { editor.redo() } else { editor.undo() }
            handled = true
        } else if keyCode == Key.delete || keyCode == Key.forwardDelete, !command {
            editor.deleteSelected()
            handled = true
        } else if !command, let tool = ScreenshotAnnotationTool(keyCode: keyCode) {
            editor.selectTool(tool)
            handled = true
        } else if editor.selected != nil, let offset = Self.nudgeOffset(for: keyCode, modifiers: modifiers) {
            editor.nudgeSelected(by: offset)
            handled = true
        } else {
            handled = false
        }
        if handled { refresh() }
        return handled
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
        guard onActivate?(self) ?? true else { return }
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
        endTextEditing()
        guard let rect = selection.rect, !selection.isDragging, !editor.isDragging else { return }
        onEvent?(self, .finish(action, rect, editor.document.annotations))
    }

    // MARK: Toolbar

    func perform(_ action: ScreenshotEditorToolbarModel.Action) {
        endTextEditing()
        switch action {
        case let .tool(tool): editor.selectTool(tool)
        case let .color(color): editor.setColor(color)
        case let .width(width): editor.setWidth(width)
        case let .mosaicEffect(effect): editor.setMosaicEffect(effect)
        case let .mosaicStrength(strength): editor.setMosaicStrength(strength)
        case let .mosaicShape(shape): editor.setMosaicShape(shape)
        case .undo: editor.undo()
        case .redo: editor.redo()
        case .cancel: onEvent?(self, .cancelled)
        case .save: finish(.save)
        case .copy: finish(.copy)
        }
        // Keys go back to the overlay after a click on the toolbar.
        window?.makeFirstResponder(self)
        refresh()
    }

    // MARK: Text

    private func beginTextEditing(at origin: CGPoint, text: String, fontSize: CGFloat,
                                  color: ScreenshotAnnotationStyle.Color) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ScreenshotAnnotation.font(size: fontSize)
        field.textColor = NSColor(cgColor: color.cgColor())
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = ScreenshotOverlayChromeView.accent.cgColor
        textOrigin = origin
        textField = field
        addSubview(field, positioned: .below, relativeTo: chrome)
        resizeTextField()
        window?.makeFirstResponder(field)
    }

    /// Keeps the field as wide as its text, with the text where the annotation will draw it.
    private func resizeTextField() {
        guard let field = textField, let font = field.font else { return }
        let size = ScreenshotAnnotation.textSize(field.stringValue, fontSize: font.pointSize)
        field.frame = CGRect(x: textOrigin.x - Self.textFieldInset, y: textOrigin.y,
                             width: max(size.width, font.pointSize) + Self.textFieldInset * 2 + 4,
                             height: size.height)
    }

    /// How far a borderless field indents its text.
    static let textFieldInset: CGFloat = 2

    /// Commits the text being typed, if any.
    func endTextEditing() {
        guard let field = textField else { return }
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        editor.commitText(field.stringValue, at: textOrigin)
        window?.makeFirstResponder(self)
        refresh()
    }

    /// Esc while typing: drops the new text, or keeps the edited one as it was.
    func cancelTextEditing() {
        guard let field = textField else { return }
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        editor.cancelText()
        window?.makeFirstResponder(self)
        refresh()
    }

    // MARK: Mosaic

    /// The text height under a new mosaic, in points, from the frozen image inside the region.
    private func measureTextHeight(under mosaic: ScreenshotMosaic) -> CGFloat? {
        guard let textMeasurer, let crop = selection.rect else { return nil }
        let region = mosaic.frame.intersection(crop)
        guard !region.isNull,
              let pixels = ScreenCaptureGeometry.pixelRect(for: region, displayFrame: bounds,
                                                           imageSize: display.pixelSize),
              let piece = display.image.cropping(to: pixels),
              let height = textMeasurer.tallestLineHeight(in: piece) else { return nil }
        return height / max(CGFloat(display.image.height) / max(bounds.height, 1), 1)
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
            loupe: showsLoupe ? loupe() : nil
        )
        let selected = editor.editingTextID == nil ? editor.selected : nil
        canvas.model = ScreenshotAnnotationCanvasView.Model(crop: selection.rect,
                                                            annotations: editor.visibleAnnotations,
                                                            selection: selected?.frame,
                                                            handles: editor.selectionHandles)
        refreshToolbar()
    }

    private func refreshToolbar() {
        // A selected mark shows its own color, size and mosaic options; changing them restyles it.
        let selected = editor.selected
        let mosaic = selected?.mosaic
        let state = ScreenshotEditorToolbarModel.State(
            tool: editor.tool, style: selected?.style ?? editor.style,
            mosaicEffect: mosaic?.effect ?? editor.mosaicEffect,
            mosaicStrength: mosaic?.strength ?? editor.mosaicStrength,
            mosaicShape: mosaic.map { if case .brush = $0.shape { .brush } else { .rect } } ?? editor.mosaicShape,
            canUndo: editor.document.canUndo, canRedo: editor.document.canRedo,
            showsOptions: editor.tool != nil || editor.selected != nil,
            showsMosaicOptions: editor.showsMosaicOptions
        )
        toolbarModel.state = state
        guard let rect = selection.rect, !selection.isDragging else {
            toolbar?.isHidden = true
            return
        }
        let host: ScreenshotToolbarHostingView
        if let toolbar {
            host = toolbar
            if host.shownState != state { host.rootView = toolbarView() }
        } else {
            host = ScreenshotToolbarHostingView(rootView: toolbarView())
            host.hitInset = Self.toolbarShadowInset
            addSubview(host)
            toolbar = host
        }
        host.shownState = state
        host.isHidden = false
        let inset = Self.toolbarShadowInset
        let fitting = host.fittingSize
        let content = CGSize(width: max(fitting.width - inset * 2, 0), height: max(fitting.height - inset * 2, 0))
        host.frame = ScreenshotOverlayChromeView.toolbarFrame(for: rect, size: content, in: bounds)
            .insetBy(dx: -inset, dy: -inset)
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

    private func toolbarView() -> AnyView {
        AnyView(ScreenshotEditorToolbar(state: toolbarModel.state) { [weak self] in self?.toolbarModel.perform($0) }
            .padding(Self.toolbarShadowInset))
    }

    private func updateCursor(at point: CGPoint) {
        if let crop = selection.rect, !selection.isDragging, crop.contains(point) {
            if editor.document.hit(at: point) != nil {
                NSCursor.pointingHand.set()
                return
            }
            if let tool = editor.tool, selection.hit(at: point) == .inside {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
                return
            }
        }
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

extension ScreenshotOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        resizeTextField()
    }

    /// Return commits the text and esc drops it, instead of ending or cancelling the screenshot.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endTextEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditing()
            return true
        default:
            return false
        }
    }
}
