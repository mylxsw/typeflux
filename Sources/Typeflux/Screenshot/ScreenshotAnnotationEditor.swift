import CoreGraphics
import Foundation

enum ScreenshotAnnotationTool: String, CaseIterable, Equatable {
    case rect, ellipse, line, arrow, pen, highlighter, text, counter, callout, mosaic

    /// The letter shown in tooltips.
    var shortcut: String {
        switch self {
        case .rect: "R"
        case .ellipse: "O"
        case .line: "L"
        case .arrow: "A"
        case .pen: "P"
        case .highlighter: "H"
        case .text: "T"
        case .counter: "N"
        case .callout: "C"
        case .mosaic: "M"
        }
    }

    /// The key that picks the tool, as a virtual key code (ANSI layout).
    var keyCode: UInt16 {
        switch self {
        case .rect: 15
        case .ellipse: 31
        case .line: 37
        case .arrow: 0
        case .pen: 35
        case .highlighter: 4
        case .text: 17
        case .counter: 45
        case .callout: 8
        case .mosaic: 46
        }
    }

    init?(keyCode: UInt16) {
        guard let tool = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = tool
    }
}

/// Drawing, picking and changing annotations inside the chosen region. Pure state: the
/// overlay feeds it pointer and key input in the display's own points and draws the result.
// swiftlint:disable:next type_body_length
struct ScreenshotAnnotationEditor {
    enum MosaicShape: String, CaseIterable, Equatable, Codable {
        case rect, ellipse, brush
    }

    /// What a press did.
    enum Press: Equatable {
        /// Not for the editor: the region itself handles it.
        case ignored
        case handled
        /// Start typing a new text annotation here.
        case beginText(at: CGPoint)
        /// Edit the text of an existing annotation.
        case editText(UUID)
    }

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(start: CGPoint, original: ScreenshotAnnotation, before: [ScreenshotAnnotation])
        case resizing(anchor: CGPoint, original: ScreenshotAnnotation, before: [ScreenshotAnnotation])
        /// The middle handle of a curved or elbow arrow, or the point a callout points at.
        case bending(original: ScreenshotAnnotation, before: [ScreenshotAnnotation])
    }

    static let handleHitRadius: CGFloat = 6
    /// Shorter arrows and smaller boxes are treated as stray clicks.
    static let minimumShapeSize: CGFloat = 3
    /// Freehand points closer than this to the last one are skipped.
    static let minimumPointSpacing: CGFloat = 1

    private(set) var tool: ScreenshotAnnotationTool?
    /// Each tool's style and the mosaic options; the overlay keeps them in a store between screenshots.
    private(set) var toolStyles: ScreenshotToolStyles
    private(set) var document = ScreenshotAnnotationDocument()
    private(set) var selectedID: UUID?
    /// The annotation being drawn, not yet in the document.
    private(set) var draft: ScreenshotAnnotation?
    /// The text annotation whose text is being edited; the overlay shows a field instead of it.
    private(set) var editingTextID: UUID?
    /// A callout just drawn, waiting for its text; it joins the document once the text is typed.
    private(set) var calloutDraft: ScreenshotAnnotation?
    private var drag: Drag?
    /// The annotations before a slider drag began, so the whole drag undoes in one step.
    private var styleChangeStart: [ScreenshotAnnotation]?

    init(toolStyles: ScreenshotToolStyles = ScreenshotToolStyles()) {
        self.toolStyles = toolStyles
    }

    /// Styles changed elsewhere, such as on another display; what is drawn keeps its own.
    mutating func replaceToolStyles(_ styles: ScreenshotToolStyles) {
        toolStyles = styles
    }

    /// The picked tool's style; the rectangle's when no tool is picked.
    var style: ScreenshotAnnotationStyle { toolStyles[tool ?? .rect] }
    var mosaicEffect: ScreenshotMosaic.Effect { toolStyles.mosaicEffect }
    var mosaicStrength: ScreenshotMosaic.Strength { toolStyles.mosaicStrength }
    var mosaicShape: MosaicShape { toolStyles.mosaicShape }

    /// The style the options bar shows and changes: the selected annotation's, else the tool's.
    var shownStyle: ScreenshotAnnotationStyle? {
        if let selected { return selected.style }
        return tool.map { toolStyles[$0] }
    }

    /// The tool whose options the bar shows: the selected annotation's, else the picked one.
    var optionsTool: ScreenshotAnnotationTool? {
        selected?.tool ?? tool
    }

    /// The size the slider shows, in the options tool's range.
    var shownSize: CGFloat? {
        if let selected { return selected.size }
        return tool.map { toolStyles[$0].size }
    }

    /// Measures the text under a new mosaic, in points.
    var measureTextHeight: (ScreenshotMosaic) -> CGFloat? = { _ in nil }
    /// Finds the lines of text inside a rectangle, in points, for mosaics that only cover text.
    var locateText: (CGRect) -> [CGRect] = { _ in [] }

    struct GeometryRequest {
        let id = UUID()
        let annotationID: UUID
        let mosaic: ScreenshotMosaic
        let scope: ScreenshotMosaic.Scope
    }
    var preparesMosaicGeometry = false
    private(set) var geometryRequest: GeometryRequest?

    mutating func cancelGeometry() { geometryRequest = nil }

    mutating func completeGeometry(_ id: UUID, geometry: ScreenshotTextGeometry) {
        guard let request = geometryRequest, request.id == id,
              var annotation = document.annotation(id: request.annotationID), annotation.mosaic == request.mosaic else { return }
        geometryRequest = nil
        var mosaic = request.mosaic
        mosaic.textHeight = geometry.height
        if request.scope == .text, mosaic.shape.coversArea {
            let shape = mosaic.maskPath
            let runs = geometry.lines.filter { shape.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            if !runs.isEmpty { mosaic.textRuns = runs; mosaic.textHeight = runs.map(\.height).max() }
        }
        annotation.kind = .mosaic(mosaic)
        document.update(annotation, recordingUndo: false)
    }

    var isDragging: Bool { drag != nil }

    var selected: ScreenshotAnnotation? {
        selectedID.flatMap(document.annotation(id:))
    }

    /// What the overlay draws: the document, then the draft, without the text being edited. A callout
    /// being edited keeps its line and box, with the field over the box.
    var visibleAnnotations: [ScreenshotAnnotation] {
        let shown = document.annotations.compactMap { annotation -> ScreenshotAnnotation? in
            guard annotation.id == editingTextID else { return annotation }
            guard case let .callout(anchor, origin, _, fontSize) = annotation.kind else { return nil }
            var bare = annotation
            bare.kind = .callout(anchor: anchor, origin: origin, "", fontSize: fontSize)
            return bare
        }
        return shown + (draft.map { [$0] } ?? []) + (calloutDraft.map { [$0] } ?? [])
    }

    /// The corners that resize the selected annotation.
    var selectionHandles: [CGPoint] {
        guard let selected, selected.isResizable, editingTextID == nil else { return [] }
        return Self.corners(of: selected.frame)
    }

    /// The handle that bends the selected curved or elbow arrow.
    var bendHandle: CGPoint? {
        guard editingTextID == nil else { return nil }
        return selected?.bendHandle
    }

    /// The number the counters start from: the first counter's, else the counter tool's.
    var counterStart: Int {
        document.annotations.first { if case .counter = $0.kind { true } else { false } }?.style.counterStart
            ?? toolStyles[.counter].counterStart
    }

    /// The selected annotation is a mosaic, or the mosaic tool is picked: the sub-bar shows mosaic options.
    var showsMosaicOptions: Bool {
        if let selected { return selected.isMosaic }
        return tool == .mosaic
    }

    // MARK: Pointer

    /// - Parameters:
    ///   - crop: the chosen region.
    ///   - cropHit: where the press lands on the region; its handles win over drawing.
    mutating func mouseDown(at point: CGPoint, clickCount: Int = 1, shift: Bool = false, crop: CGRect,
                            cropHit: ScreenshotSelection.Hit) -> Press {
        drag = nil
        if let selected, let handle = bendHandle,
           hypot(handle.x - point.x, handle.y - point.y) <= Self.handleHitRadius {
            drag = .bending(original: selected, before: document.annotations)
            return .handled
        }
        if let selected, let corner = Self.corners(of: selected.frame).firstIndex(where: {
            hypot($0.x - point.x, $0.y - point.y) <= Self.handleHitRadius
        }), selected.isResizable {
            drag = .resizing(anchor: Self.corners(of: selected.frame)[(corner + 2) % 4], original: selected,
                             before: document.annotations)
            return .handled
        }
        if case .handle = cropHit { return .ignored }
        if crop.contains(point), let hit = document.hit(at: point) {
            selectedID = hit.id
            if clickCount >= 2, hit.editableText != nil {
                editingTextID = hit.id
                return .editText(hit.id)
            }
            drag = .moving(start: point, original: hit, before: document.annotations)
            return .handled
        }
        selectedID = nil
        guard let tool, cropHit == .inside else { return .ignored }
        if tool == .text { return .beginText(at: point) }
        draft = makeDraft(tool, at: point)
        drag = .drawing(start: point)
        return .handled
    }

    /// - Returns: whether anything changed.
    @discardableResult
    mutating func mouseDragged(to point: CGPoint, shift: Bool = false) -> Bool {
        switch drag {
        case let .drawing(start):
            guard let current = draft else { return false }
            draft = extended(current, from: start, to: point, shift: shift)
            return true
        case let .moving(start, original, _):
            // A callout moves its box; the point it points at stays where it is.
            return document.update(original.movingCalloutBox(dx: point.x - start.x, dy: point.y - start.y),
                                   recordingUndo: false)
        case let .resizing(anchor, original, _):
            var target = point
            if shift { target = Self.constrainedSquare(from: anchor, to: point) }
            let frame = ScreenshotSelection.rect(from: anchor, to: target)
            return document.update(original.resized(from: original.frame, to: frame), recordingUndo: false)
        case let .bending(original, _):
            if case let .callout(_, origin, text, fontSize) = original.kind {
                var moved = original
                moved.kind = .callout(anchor: point, origin: origin, text, fontSize: fontSize)
                return document.update(moved, recordingUndo: false)
            }
            guard case let .arrow(from, to) = original.kind else { return false }
            var bent = original
            bent.style.arrowBend = ScreenshotAnnotation.arrowBend(through: point, from: from, to: to,
                                                                   path: original.style.arrowPath)
            return document.update(bent, recordingUndo: false)
        case nil:
            return false
        }
    }

    /// - Returns: whether anything changed.
    @discardableResult
    mutating func mouseUp(at point: CGPoint, shift: Bool = false) -> Bool {
        defer { drag = nil }
        switch drag {
        case .drawing:
            defer { draft = nil }
            // A callout waits for its text before it joins the document.
            if let callout = draft, case .callout = callout.kind {
                calloutDraft = callout
                return true
            }
            guard var finished = draft, Self.isWorthKeeping(finished) else { return draft != nil }
            if let mosaic = finished.mosaic {
                finished.kind = .mosaic(finishedMosaic(mosaic, scope: toolStyles.mosaicScope, annotationID: finished.id))
            }
            if case let .path(points) = finished.kind, finished.style.smoothed {
                finished.kind = .path(ScreenshotStrokeSmoothing.smoothed(points))
            }
            document.add(finished)
            return true
        case let .moving(_, _, before), let .resizing(_, _, before), let .bending(_, before):
            document.commit(from: before)
            return true
        case nil:
            return false
        }
    }

    private func makeDraft(_ tool: ScreenshotAnnotationTool, at point: CGPoint) -> ScreenshotAnnotation {
        let empty = CGRect(origin: point, size: .zero)
        var style = toolStyles[tool]
        if tool == .arrow, style.arrowPath == .curve { style.arrowBend = ScreenshotAnnotationStyle.defaultCurveBend }
        if tool == .counter { style.counterStart = counterStart }
        let mosaicDraftShape: ScreenshotMosaic.Shape = switch mosaicShape {
        case .rect: .rect(empty)
        case .ellipse: .ellipse(empty)
        case .brush: .brush([point], width: style.brushWidth)
        }
        let kind: ScreenshotAnnotation.Kind = switch tool {
        case .rect: .rect(empty)
        case .ellipse: .ellipse(empty)
        case .line: .line(from: point, to: point)
        case .arrow: .arrow(from: point, to: point)
        case .pen: .path([point])
        case .highlighter: .highlight([point])
        case .text: .text(origin: point, "", fontSize: style.fontSize)
        case .counter: .counter(center: point)
        case .callout: .callout(anchor: point, origin: point, "", fontSize: style.fontSize)
        case .mosaic: .mosaic(ScreenshotMosaic(shape: mosaicDraftShape, effect: mosaicEffect,
                                               strength: mosaicStrength))
        }
        return ScreenshotAnnotation(kind: kind, style: style)
    }

    private func extended(_ draft: ScreenshotAnnotation, from start: CGPoint, to point: CGPoint,
                          shift: Bool) -> ScreenshotAnnotation {
        var draft = draft
        let square = shift ? Self.constrainedSquare(from: start, to: point) : point
        let angled = shift ? Self.constrainedAngle(from: start, to: point) : point
        func stroke(_ points: [CGPoint]) -> [CGPoint] {
            if shift { return [start, angled] }
            guard let last = points.last, hypot(point.x - last.x, point.y - last.y) >= Self.minimumPointSpacing
            else { return points }
            return points + [point]
        }
        switch draft.kind {
        case .rect: draft.kind = .rect(ScreenshotSelection.rect(from: start, to: square))
        case .ellipse: draft.kind = .ellipse(ScreenshotSelection.rect(from: start, to: square))
        case .line: draft.kind = .line(from: start, to: angled)
        case .arrow:
            draft.kind = .arrow(from: start, to: angled)
            // An elbow turns the way the drag mostly went.
            if draft.style.arrowPath == .elbow {
                draft.style.arrowBend = abs(angled.x - start.x) >= abs(angled.y - start.y) ? 1 : -1
            }
        case let .path(points): draft.kind = .path(stroke(points))
        case let .highlight(points):
            draft.kind = .highlight(draft.style.highlighterMode == .straight ? [start, angled] : stroke(points))
        case .counter:
            // A bubble stays where the press was and points where the drag goes; a circle follows the pointer.
            if draft.style.counterShape == .bubble {
                if hypot(point.x - start.x, point.y - start.y) >= Self.minimumShapeSize {
                    draft.style.counterAngle = atan2(point.y - start.y, point.x - start.x)
                }
            } else {
                draft.kind = .counter(center: point)
            }
        case let .callout(anchor, _, text, fontSize):
            // The box follows the pointer, a little below its tip; the line stays on the press.
            draft.kind = .callout(anchor: anchor, origin: point, text, fontSize: fontSize)
        case var .mosaic(mosaic):
            switch mosaic.shape {
            case .rect: mosaic.shape = .rect(ScreenshotSelection.rect(from: start, to: square))
            case .ellipse: mosaic.shape = .ellipse(ScreenshotSelection.rect(from: start, to: square))
            case let .brush(points, width): mosaic.shape = .brush(stroke(points), width: width)
            }
            draft.kind = .mosaic(mosaic)
        case .text: break
        }
        return draft
    }

    static func isWorthKeeping(_ annotation: ScreenshotAnnotation) -> Bool {
        switch annotation.kind {
        case let .rect(rect), let .ellipse(rect):
            return rect.width >= minimumShapeSize && rect.height >= minimumShapeSize
        case let .line(from, to), let .arrow(from, to):
            return hypot(to.x - from.x, to.y - from.y) >= minimumShapeSize
        case let .mosaic(mosaic):
            switch mosaic.shape {
            case let .rect(rect), let .ellipse(rect):
                return rect.width >= minimumShapeSize && rect.height >= minimumShapeSize
            case .brush:
                return true
            }
        case let .text(_, text, _), let .callout(_, _, text, _):
            return !text.isEmpty
        case .path, .highlight, .counter:
            return true
        }
    }

    // MARK: Text

    /// Ends typing: adds the new text or callout, or replaces (or, when emptied, removes) the edited one.
    mutating func commitText(_ text: String, at origin: CGPoint) {
        defer { editingTextID = nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var callout = calloutDraft {
            calloutDraft = nil
            guard !trimmed.isEmpty, case let .callout(anchor, boxOrigin, _, fontSize) = callout.kind else { return }
            callout.kind = .callout(anchor: anchor, origin: boxOrigin, text, fontSize: fontSize)
            document.add(callout)
            return
        }
        if let id = editingTextID, var edited = document.annotation(id: id) {
            if trimmed.isEmpty {
                document.remove(id: id)
                selectedID = nil
                return
            }
            switch edited.kind {
            case let .text(oldOrigin, _, fontSize):
                edited.kind = .text(origin: oldOrigin, text, fontSize: fontSize)
            case let .callout(anchor, boxOrigin, _, fontSize):
                edited.kind = .callout(anchor: anchor, origin: boxOrigin, text, fontSize: fontSize)
            default:
                return
            }
            document.update(edited)
            return
        }
        guard !trimmed.isEmpty else { return }
        let style = toolStyles[.text]
        document.add(ScreenshotAnnotation(kind: .text(origin: origin, text, fontSize: style.fontSize), style: style))
    }

    mutating func cancelText() {
        editingTextID = nil
        calloutDraft = nil
    }

    // MARK: Commands

    /// Picks a tool, or puts it down when it is already picked.
    mutating func selectTool(_ tool: ScreenshotAnnotationTool?) {
        self.tool = self.tool == tool ? nil : tool
        selectedID = nil
    }

    mutating func deselect() {
        selectedID = nil
    }

    // MARK: Style

    /// Changes the selected annotation, or the picked tool's style when nothing is selected, so
    /// restyling one mark never changes what the next one looks like.
    private mutating func restyle(_ change: (inout ScreenshotAnnotationStyle) -> Void) {
        if var annotation = selected {
            change(&annotation.style)
            annotation.style = ScreenshotToolStyles.normalized(annotation.style, for: annotation.tool)
            updateSelected(annotation)
        } else if let tool {
            change(&toolStyles[tool])
        }
    }

    private mutating func updateSelected(_ annotation: ScreenshotAnnotation) {
        document.update(annotation, recordingUndo: styleChangeStart == nil)
    }

    mutating func setColor(_ color: ScreenshotAnnotationStyle.Color) {
        guard selected != nil || tool != nil else { return }
        restyle { $0.color = color }
        toolStyles.noteRecent(color)
    }

    /// The tool's size, or the selected annotation's (the font size of text, the width of a brush).
    mutating func setSize(_ size: CGFloat) {
        if var annotation = selected {
            annotation.size = ScreenshotToolStyles.clamp(size, to: annotation.tool.sizeRange)
            updateSelected(annotation)
        } else if let tool {
            toolStyles[tool].size = size
        }
    }

    /// `[` and `]`: one step smaller or larger.
    mutating func stepSize(by steps: Int) {
        guard let tool = optionsTool, let size = shownSize else { return }
        setSize(size + CGFloat(steps) * tool.sizeStep)
    }

    /// Virtual key codes of 1, 2 … 9, 0 (ANSI layout), the order of the preset colors.
    static let colorKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    static let smallerKeyCode: UInt16 = 33
    static let largerKeyCode: UInt16 = 30

    /// Whether the options bar offers a color now: tools that draw in a color, and solid mosaics.
    var offersColor: Bool {
        guard let tool = optionsTool else { return false }
        if tool == .mosaic { return (selected?.mosaic?.effect ?? mosaicEffect) == .solid }
        return tool.usesColor
    }

    /// 1–0 pick a preset color and `[` `]` change the size, while a tool is picked or a mark is selected.
    /// - Returns: whether the key meant something here.
    mutating func handleStyleKey(_ keyCode: UInt16) -> Bool {
        guard optionsTool != nil else { return false }
        if let index = Self.colorKeyCodes.firstIndex(of: keyCode) {
            guard offersColor else { return false }
            setColor(ScreenshotAnnotationStyle.Color.presets[index])
            return true
        }
        switch keyCode {
        case Self.smallerKeyCode: stepSize(by: -1)
        case Self.largerKeyCode: stepSize(by: 1)
        default: return false
        }
        return true
    }

    /// Changes the options tool's style only: options that shape what is drawn next, such as smoothing.
    private mutating func restyleTool(_ change: (inout ScreenshotAnnotationStyle) -> Void) {
        guard let tool = optionsTool else { return }
        change(&toolStyles[tool])
    }

    mutating func setArrowHead(_ head: ScreenshotAnnotationStyle.ArrowHead) {
        restyle { $0.arrowHead = head }
    }

    /// A selected arrow that becomes curved bows by the default amount; an elbow turns the way it is longer.
    mutating func setArrowPath(_ path: ScreenshotAnnotationStyle.ArrowPath) {
        guard let selected, case let .arrow(from, to) = selected.kind else {
            restyle { $0.arrowPath = path }
            return
        }
        restyle { style in
            style.arrowPath = path
            switch path {
            case .straight:
                style.arrowBend = 0
            case .curve:
                // Coming from straight (0) or an elbow (±1): bow by the default amount.
                if style.arrowBend == 0 || abs(style.arrowBend) == 1 {
                    style.arrowBend = ScreenshotAnnotationStyle.defaultCurveBend
                }
            case .elbow:
                style.arrowBend = abs(to.x - from.x) >= abs(to.y - from.y) ? 1 : -1
            }
        }
    }

    mutating func setOutlined(_ outlined: Bool) {
        restyle { $0.outlined = outlined }
    }

    /// Smoothing happens when a stroke ends, so it only changes the pen's next strokes.
    mutating func setSmoothed(_ smoothed: Bool) {
        restyleTool { $0.smoothed = smoothed }
    }

    /// Straight or free only changes how the next stroke is drawn.
    mutating func setHighlighterMode(_ mode: ScreenshotAnnotationStyle.HighlighterMode) {
        restyleTool { $0.highlighterMode = mode }
    }

    mutating func setHighlighterTip(_ tip: ScreenshotAnnotationStyle.HighlighterTip) {
        restyle { $0.highlighterTip = tip }
    }

    mutating func setFont(_ font: ScreenshotAnnotationStyle.TextFont) {
        restyle { $0.font = font }
    }

    mutating func setTextStyle(_ textStyle: ScreenshotAnnotationStyle.TextStyle) {
        restyle { $0.textStyle = textStyle }
    }

    mutating func setCalloutAnchor(_ anchor: ScreenshotAnnotationStyle.CalloutAnchor) {
        restyle { $0.calloutAnchor = anchor }
    }

    mutating func setCounterLabel(_ label: ScreenshotAnnotationStyle.CounterLabel) {
        restyle { $0.counterLabel = label }
    }

    mutating func setCounterShape(_ shape: ScreenshotAnnotationStyle.CounterShape) {
        restyle { $0.counterShape = shape }
    }

    /// Counting is one sequence, so the start applies to the counter tool and every counter, as one undo step.
    mutating func setCounterStart(_ start: Int) {
        let range = ScreenshotAnnotationStyle.counterStartRange
        let start = min(max(start, range.lowerBound), range.upperBound)
        toolStyles[.counter].counterStart = start
        let before = document.annotations
        for var annotation in before where annotation.tool == .counter && annotation.style.counterStart != start {
            annotation.style.counterStart = start
            document.update(annotation, recordingUndo: false)
        }
        if styleChangeStart == nil { document.commit(from: before) }
    }

    mutating func setOpacity(_ opacity: CGFloat) {
        restyle { $0.opacity = opacity }
    }

    mutating func setDash(_ dash: ScreenshotAnnotationStyle.Dash) {
        restyle { $0.dash = dash }
    }

    mutating func setFill(_ fill: ScreenshotAnnotationStyle.Fill) {
        restyle { $0.fill = fill }
    }

    mutating func setCornerRadius(_ radius: CGFloat) {
        restyle { $0.cornerRadius = radius }
    }

    /// A slider drag starts: its changes to the selected annotation become one undo step.
    mutating func beginStyleChange() {
        guard styleChangeStart == nil else { return }
        styleChangeStart = document.annotations
    }

    mutating func endStyleChange() {
        guard let start = styleChangeStart else { return }
        styleChangeStart = nil
        document.commit(from: start)
    }

    mutating func setMosaicEffect(_ effect: ScreenshotMosaic.Effect) {
        if let annotation = selected, var mosaic = annotation.mosaic {
            mosaic.effect = effect
            var changed = annotation
            changed.kind = .mosaic(mosaic)
            updateSelected(changed)
        } else {
            toolStyles.mosaicEffect = effect
        }
    }

    mutating func setMosaicStrength(_ strength: ScreenshotMosaic.Strength) {
        if let annotation = selected, var mosaic = annotation.mosaic {
            mosaic.strength = strength
            var changed = annotation
            changed.kind = .mosaic(mosaic)
            updateSelected(changed)
        } else {
            toolStyles.mosaicStrength = strength
        }
    }

    mutating func setMosaicShape(_ shape: MosaicShape) {
        toolStyles.mosaicShape = shape
    }

    /// "Reset styles" in the More menu.
    mutating func resetToolStyles() {
        toolStyles.resetStyles()
    }

    mutating func toggleToolbarPlacement() {
        toolStyles.prefersToolbarAbove.toggle()
    }

    /// A selected box or ellipse mosaic is covered again over everything, or over its text only.
    mutating func setMosaicScope(_ scope: ScreenshotMosaic.Scope) {
        guard let annotation = selected, let mosaic = annotation.mosaic else {
            toolStyles.mosaicScope = scope
            return
        }
        var changed = annotation
        changed.kind = .mosaic(finishedMosaic(mosaic, scope: scope, annotationID: annotation.id))
        updateSelected(changed)
    }

    /// The text scope only exists for a selected box or ellipse mosaic, or the mosaic tool with one of those shapes.
    var mosaicScope: ScreenshotMosaic.Scope {
        selected?.mosaic?.scope ?? toolStyles.mosaicScope
    }

    /// Measures the text under a mosaic and, with the text scope, keeps only its lines; with no text
    /// found it covers the whole shape, so nothing is left uncovered by mistake.
    private mutating func finishedMosaic(_ mosaic: ScreenshotMosaic, scope: ScreenshotMosaic.Scope, annotationID: UUID) -> ScreenshotMosaic {
        var mosaic = mosaic
        mosaic.textRuns = nil
        if preparesMosaicGeometry {
            // Until preparation succeeds, cover the whole shape with conservative block sizing.
            mosaic.textHeight = mosaic.frame.height
            geometryRequest = GeometryRequest(annotationID: annotationID, mosaic: mosaic, scope: scope)
            return mosaic
        }
        if scope == .text, mosaic.shape.coversArea {
            let shape = mosaic.maskPath
            let runs = locateText(mosaic.frame).filter { shape.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            if !runs.isEmpty {
                mosaic.textRuns = runs
                mosaic.textHeight = runs.map(\.height).max()
                return mosaic
            }
        }
        mosaic.textHeight = measureTextHeight(mosaic)
        return mosaic
    }

    /// - Returns: whether an annotation was removed.
    @discardableResult
    mutating func deleteSelected() -> Bool {
        guard let selectedID, drag == nil else { return false }
        self.selectedID = nil
        return document.remove(id: selectedID)
    }

    /// Arrow keys move the selected annotation.
    @discardableResult
    mutating func nudgeSelected(by offset: CGSize) -> Bool {
        guard let selected, drag == nil else { return false }
        return document.update(selected.offsetBy(dx: offset.width, dy: offset.height))
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard drag == nil, document.undo() else { return false }
        dropMissingSelection()
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard drag == nil, document.redo() else { return false }
        dropMissingSelection()
        return true
    }

    /// Covers each rectangle with a mosaic in the current effect and strength, all as one
    /// undo step; the text height is the rectangle's, as it covers one line of text.
    /// - Returns: the new annotations' ids, in the order of `rects`.
    @discardableResult
    mutating func addMosaics(over rects: [CGRect]) -> [UUID] {
        guard drag == nil else { return [] }
        let added = rects.map { rect in
            ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(rect), effect: mosaicEffect,
                                                                strength: mosaicStrength, textHeight: rect.height)),
                                 style: toolStyles[.mosaic])
        }
        document.add(added)
        return added.map(\.id)
    }

    /// Removes these annotations as one undo step.
    @discardableResult
    mutating func removeAnnotations(_ ids: Set<UUID>) -> Bool {
        guard drag == nil, document.remove(ids: ids) else { return false }
        dropMissingSelection()
        return true
    }

    private mutating func dropMissingSelection() {
        if let selectedID, document.annotation(id: selectedID) == nil { self.selectedID = nil }
    }

    // MARK: Geometry

    /// Top-left, top-right, bottom-right, bottom-left: opposite corners are two apart.
    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// ⇧ while drawing a box: the point that makes it a square.
    static func constrainedSquare(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    /// ⇧ while drawing a line: the point at the same distance on the nearest multiple of 45°.
    static func constrainedAngle(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return start }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        // Snap exact axes, so 0° and 90° do not drift by a rounding error.
        let x = abs(cos(angle)) < 1e-9 ? 0 : cos(angle) * length
        let y = abs(sin(angle)) < 1e-9 ? 0 : sin(angle) * length
        return CGPoint(x: start.x + x, y: start.y + y)
    }
}

extension ScreenshotAnnotationEditor {
    /// Applies a toolbar action that only changes the marks, the tools or their style, the same
    /// way in the region overlay and the long image editor.
    /// - Returns: false for actions the view handles itself: finishing, the color panel, picking a color.
    @discardableResult
    mutating func apply(_ action: ScreenshotEditorToolbarModel.Action) -> Bool {
        switch action {
        case let .tool(tool): selectTool(tool)
        case let .color(color): setColor(color)
        case let .size(size): setSize(size)
        case let .opacity(opacity): setOpacity(opacity)
        case let .dash(dash): setDash(dash)
        case let .fill(fill): setFill(fill)
        case let .cornerRadius(radius): setCornerRadius(radius)
        case let .styleChange(began): if began { beginStyleChange() } else { endStyleChange() }
        case let .mosaicEffect(effect): setMosaicEffect(effect)
        case let .mosaicStrength(strength): setMosaicStrength(strength)
        case let .mosaicShape(shape): setMosaicShape(shape)
        case let .arrowHead(head): setArrowHead(head)
        case let .arrowPath(path): setArrowPath(path)
        case let .outlined(outlined): setOutlined(outlined)
        case let .smoothed(smoothed): setSmoothed(smoothed)
        case let .highlighterMode(mode): setHighlighterMode(mode)
        case let .highlighterTip(tip): setHighlighterTip(tip)
        case let .font(font): setFont(font)
        case let .textStyle(textStyle): setTextStyle(textStyle)
        case let .counterLabel(label): setCounterLabel(label)
        case let .counterShape(shape): setCounterShape(shape)
        case let .counterStart(start): setCounterStart(start)
        case let .calloutAnchor(anchor): setCalloutAnchor(anchor)
        case let .mosaicScope(scope): setMosaicScope(scope)
        case .undo: undo()
        case .redo: redo()
        case .resetStyles: resetToolStyles()
        case .toggleToolbarPlacement: toggleToolbarPlacement()
        case .toggleColorPanel, .pickColor, .cancel, .save, .copy, .copyAndSave, .pin, .scrollCapture, .record, .followUp,
             .toggleMoreMenu, .toggleSensitivePanel, .dragToolbar:
            return false
        }
        return true
    }
}
