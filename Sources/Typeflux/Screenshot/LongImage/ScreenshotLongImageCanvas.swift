import AppKit

/// The long image at its size in points, with the annotations over it, inside the editor's scroll
/// view. Everything here is in the image's own points, whatever the zoom: the scroll view scales the
/// whole view. It takes the pointer and the keys and feeds them to `ScreenshotAnnotationEditor`,
/// the same editor the region overlay uses, with the whole image as the region.
@MainActor
final class ScreenshotLongImageCanvas: NSView {
    enum Event: Equatable {
        case finish(ScreenshotOutputAction, [ScreenshotAnnotation])
        case cancelled
        /// ⌘+ (positive), ⌘− (negative) or ⌘0 (zero, back to the width).
        case zoom(Int)
    }

    let image: CGImage
    /// Pixels per point of the image.
    let scale: CGFloat
    private(set) var editor = ScreenshotAnnotationEditor()
    private let canvas: ScreenshotAnnotationCanvasView
    private let textMeasurer: (any ScreenshotTextHeightMeasuring)?
    /// The field for typing a text annotation, while one is typed.
    private(set) var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    var onEvent: ((Event) -> Void)?
    /// Called after every change, so the toolbar and the minimap can follow.
    var onChange: (() -> Void)?

    init(image: CGImage, scale: CGFloat, textMeasurer: (any ScreenshotTextHeightMeasuring)? = nil) {
        self.image = image
        self.scale = max(scale, 1)
        self.textMeasurer = textMeasurer
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / self.scale,
                            height: CGFloat(image.height) / self.scale)
        canvas = ScreenshotAnnotationCanvasView(frame: bounds, source: image)
        super.init(frame: bounds)
        wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        editor.measureTextHeight = { [weak self] mosaic in self?.measureTextHeight(under: mosaic) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func releaseImage() {
        canvas.releaseImage()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawImage(in: dirtyRect, context: context)
    }

    /// The part of the image under `rect`, so a tall image is never drawn whole for one tile.
    func drawImage(in rect: CGRect, context: CGContext) {
        guard let pixels = ScreenCaptureGeometry.pixelRect(
            for: rect, displayFrame: bounds, imageSize: ScreenPixelSize(width: image.width, height: image.height)
        ), let piece = image.cropping(to: pixels) else { return }
        context.interpolationQuality = .high
        ScreenshotRenderer.drawImage(piece, in: CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                                                       width: pixels.width / scale, height: pixels.height / scale),
                                     context: context)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDown(at: location(of: event), clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDragged(to: location(of: event), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        mouseUp(at: location(of: event), shift: event.modifierFlags.contains(.shift))
    }

    func mouseDown(at point: CGPoint, clickCount: Int, shift: Bool = false) {
        endTextEditing()
        window?.makeFirstResponder(self)
        let hit: ScreenshotSelection.Hit = bounds.contains(point) ? .inside : .outside
        switch editor.mouseDown(at: point, clickCount: clickCount, shift: shift, crop: bounds, cropHit: hit) {
        case let .beginText(origin):
            beginTextEditing(at: origin, text: "", fontSize: editor.style.fontSize, color: editor.style.color)
        case let .editText(id):
            if let annotation = editor.document.annotation(id: id),
               case let .text(origin, text, fontSize) = annotation.kind {
                beginTextEditing(at: origin, text: text, fontSize: fontSize, color: annotation.style.color)
            }
        case .handled, .ignored:
            break
        }
        refresh()
    }

    func mouseDragged(to point: CGPoint, shift: Bool = false) {
        guard editor.isDragging else { return }
        editor.mouseDragged(to: point, shift: shift)
        // Drawing past the visible part scrolls the image along.
        autoscroll(to: point)
        refresh()
    }

    func mouseUp(at point: CGPoint, shift: Bool = false) {
        guard editor.isDragging else { return }
        editor.mouseUp(at: point, shift: shift)
        refresh()
    }

    private func autoscroll(to point: CGPoint) {
        guard enclosingScrollView != nil, !visibleRect.contains(point) else { return }
        scrollToVisible(CGRect(origin: point, size: .zero).insetBy(dx: -8, dy: -8))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While typing, ⌘C, ⌘A, ⌘Z and the like belong to the text field.
        guard event.type == .keyDown, event.modifierFlags.contains(.command), textField == nil else { return false }
        return handleKeyDown(event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
    }

    /// - Returns: whether the key meant something here.
    @discardableResult
    func handleKeyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil) -> Bool {
        typealias Key = ScreenshotOverlayView.Key
        let command = modifiers.contains(.command)
        if command, let zoom = Self.zoomStep(keyCode: keyCode, characters: characters) {
            onEvent?(.zoom(zoom))
            return true
        }
        switch keyCode {
        case Key.escape:
            onEvent?(.cancelled)
        case Key.returnKey, Key.enter:
            finish(.copy)
        case Key.keyC where command:
            finish(.copy)
        case Key.keyS where command:
            finish(.save)
        case Key.keyZ where command:
            if modifiers.contains(.shift) { editor.redo() } else { editor.undo() }
        case Key.delete, Key.forwardDelete:
            guard !command else { return false }
            editor.deleteSelected()
        default:
            if !command, let tool = ScreenshotAnnotationTool(keyCode: keyCode) {
                editor.selectTool(tool)
            } else if !command, editor.selected != nil,
                      let offset = ScreenshotOverlayView.nudgeOffset(for: keyCode, modifiers: modifiers) {
                editor.nudgeSelected(by: offset)
            } else {
                return false
            }
        }
        refresh()
        return true
    }

    /// ⌘= / ⌘+ zoom in, ⌘− out, ⌘0 back to the width.
    static func zoomStep(keyCode: UInt16, characters: String?) -> Int? {
        switch characters {
        case "=", "+": return 1
        case "-", "_": return -1
        case "0": return 0
        default: break
        }
        switch keyCode {
        case 24, 69: return 1
        case 27, 78: return -1
        case 29, 82: return 0
        default: return nil
        }
    }

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
        case .cancel: onEvent?(.cancelled)
        case .save: finish(.save)
        case .copy: finish(.copy)
        case .scrollCapture: break
        }
        window?.makeFirstResponder(self)
        refresh()
    }

    private func finish(_ action: ScreenshotOutputAction) {
        endTextEditing()
        guard !editor.isDragging else { return }
        onEvent?(.finish(action, editor.document.annotations))
    }

    // MARK: Text

    private func beginTextEditing(at origin: CGPoint, text: String, fontSize: CGFloat,
                                  color: ScreenshotAnnotationStyle.Color) {
        let field = ScreenshotOverlayView.makeTextField(text: text, fontSize: fontSize, color: color)
        field.delegate = self
        textOrigin = origin
        textField = field
        addSubview(field)
        field.frame = ScreenshotOverlayView.textFieldFrame(for: field, at: origin)
        window?.makeFirstResponder(field)
    }

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

    /// The text height under a new mosaic, in points.
    private func measureTextHeight(under mosaic: ScreenshotMosaic) -> CGFloat? {
        let region = mosaic.frame.intersection(bounds)
        guard let textMeasurer, !region.isNull,
              let pixels = ScreenCaptureGeometry.pixelRect(
                  for: region, displayFrame: bounds, imageSize: ScreenPixelSize(width: image.width, height: image.height)
              ),
              let piece = image.cropping(to: pixels),
              let height = textMeasurer.tallestLineHeight(in: piece) else { return nil }
        return height / scale
    }

    // MARK: State

    func refresh() {
        let selected = editor.editingTextID == nil ? editor.selected : nil
        canvas.model = ScreenshotAnnotationCanvasView.Model(crop: bounds, annotations: editor.visibleAnnotations,
                                                            selection: selected?.frame,
                                                            handles: editor.selectionHandles)
        onChange?()
    }

    /// The toolbar for the editor's current state; there is no scrolling capture from a long image.
    var toolbarState: ScreenshotEditorToolbarModel.State {
        let selected = editor.selected
        let mosaic = selected?.mosaic
        return ScreenshotEditorToolbarModel.State(
            tool: editor.tool, style: selected?.style ?? editor.style,
            mosaicEffect: mosaic?.effect ?? editor.mosaicEffect,
            mosaicStrength: mosaic?.strength ?? editor.mosaicStrength,
            mosaicShape: mosaic.map { if case .brush = $0.shape { .brush } else { .rect } } ?? editor.mosaicShape,
            canUndo: editor.document.canUndo, canRedo: editor.document.canRedo,
            showsOptions: editor.tool != nil || editor.selected != nil,
            showsMosaicOptions: editor.showsMosaicOptions,
            showsScrollCapture: false
        )
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}

extension ScreenshotLongImageCanvas: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let textField else { return }
        textField.frame = ScreenshotOverlayView.textFieldFrame(for: textField, at: textOrigin)
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
