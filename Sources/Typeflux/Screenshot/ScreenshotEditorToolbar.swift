// swiftlint:disable file_length
import AppKit
import SwiftUI

/// What the editor toolbar shows and what its buttons ask for. The overlay rebuilds the
/// toolbar from `state` whenever it changes, so its size is known at once for placement.
@MainActor
final class ScreenshotEditorToolbarModel {
    struct State: Equatable {
        var showsBackgroundRemoval = false
        var supportsBackgroundRemoval = ScreenshotBackgroundRemoval.isSupported
        var isRemovingBackground = false
        var hasRemovedBackground = false
        var backgroundNoticeKey: String?
        var tool: ScreenshotAnnotationTool?
        /// Whose options the second row shows: the selected annotation's tool, else the picked one.
        var optionsTool: ScreenshotAnnotationTool?
        /// The selected annotation's style, else the picked tool's.
        var style = ScreenshotAnnotationStyle()
        /// What the size slider shows: the font size of selected text, the width of a brush, or the style's size.
        var size: CGFloat = 4
        var mosaicEffect: ScreenshotMosaic.Effect = .pixelate
        var mosaicStrength: ScreenshotMosaic.Strength = .medium
        var mosaicShape: ScreenshotAnnotationEditor.MosaicShape = .rect
        var mosaicScope: ScreenshotMosaic.Scope = .all
        var mosaicPreparation: ScreenshotMosaicPreparation.State = .idle
        var recentColors: [ScreenshotAnnotationStyle.Color] = []
        /// What the counters count from.
        var counterStart = 1
        var canUndo = false
        var canRedo = false
        /// A tool is picked or an annotation selected: the second row shows its options.
        var showsOptions = false
        var showsMosaicOptions = false
        /// The options bar starts with the color button.
        var showsColor = false
        /// The color button is open: the color panel shows under the options.
        var showsColorPanel = false
        /// The next click on the screenshot picks its color.
        var isPickingColor = false
        /// The scrolling capture button; the long image editor has none.
        var showsScrollCapture = true
        /// Scrolling capture captures the region again, so it is only offered before anything is marked.
        var canScrollCapture = true
        /// Pinning, the toolbar's grip and its placement are for the region overlay only.
        var showsPin = true
        var showsMoreMenu = false
        var prefersToolbarAbove = false
        /// Sensitive information was found, so the More menu can show or hide its panel.
        var canShowSensitivePanel = false
        var showsSensitivePanel = false

        init() {}

        /// The toolbar for an editor's current state.
        init(editor: ScreenshotAnnotationEditor, showsColorPanel: Bool, isPickingColor: Bool,
             showsScrollCapture: Bool = true, canScrollCapture: Bool = true, showsPin: Bool = true,
             showsMoreMenu: Bool = false, canShowSensitivePanel: Bool = false, showsSensitivePanel: Bool = false, mosaicPreparation: ScreenshotMosaicPreparation.State = .idle) {
            let mosaic = editor.selected?.mosaic
            tool = editor.tool
            optionsTool = editor.optionsTool
            style = editor.shownStyle ?? editor.style
            size = editor.shownSize ?? style.size
            mosaicEffect = mosaic?.effect ?? editor.mosaicEffect
            mosaicStrength = mosaic?.strength ?? editor.mosaicStrength
            mosaicShape = mosaic.map { mosaic in
                switch mosaic.shape {
                case .rect: .rect
                case .ellipse: .ellipse
                case .brush: .brush
                }
            } ?? editor.mosaicShape
            mosaicScope = editor.mosaicScope
            recentColors = editor.toolStyles.recentColors
            counterStart = editor.counterStart
            canUndo = editor.document.canUndo
            canRedo = editor.document.canRedo
            showsOptions = editor.optionsTool != nil
            showsMosaicOptions = editor.showsMosaicOptions
            showsColor = editor.offersColor
            self.showsColorPanel = showsColorPanel && editor.offersColor
            self.isPickingColor = isPickingColor
            self.showsScrollCapture = showsScrollCapture
            self.canScrollCapture = canScrollCapture
            self.showsPin = showsPin
            self.showsMoreMenu = showsMoreMenu
            prefersToolbarAbove = editor.toolStyles.prefersToolbarAbove
            self.canShowSensitivePanel = canShowSensitivePanel
            self.showsSensitivePanel = showsSensitivePanel
            self.mosaicPreparation = mosaicPreparation
        }
    }

    enum Action: Equatable {
        case tool(ScreenshotAnnotationTool)
        case color(ScreenshotAnnotationStyle.Color)
        case size(CGFloat)
        case opacity(CGFloat)
        case dash(ScreenshotAnnotationStyle.Dash)
        case fill(ScreenshotAnnotationStyle.Fill)
        case cornerRadius(CGFloat)
        /// A slider drag starts (true) or ends (false); a drag undoes in one step.
        case styleChange(began: Bool)
        /// Opens or closes the color panel.
        case toggleColorPanel
        /// The next click on the screenshot picks the color under it.
        case pickColor
        case mosaicEffect(ScreenshotMosaic.Effect)
        case mosaicStrength(ScreenshotMosaic.Strength)
        case mosaicShape(ScreenshotAnnotationEditor.MosaicShape)
        case arrowHead(ScreenshotAnnotationStyle.ArrowHead)
        case arrowPath(ScreenshotAnnotationStyle.ArrowPath)
        case outlined(Bool)
        case smoothed(Bool)
        case highlighterMode(ScreenshotAnnotationStyle.HighlighterMode)
        case highlighterTip(ScreenshotAnnotationStyle.HighlighterTip)
        case font(ScreenshotAnnotationStyle.TextFont)
        case textStyle(ScreenshotAnnotationStyle.TextStyle)
        case counterLabel(ScreenshotAnnotationStyle.CounterLabel)
        case counterShape(ScreenshotAnnotationStyle.CounterShape)
        case counterStart(Int)
        case calloutAnchor(ScreenshotAnnotationStyle.CalloutAnchor)
        case mosaicScope(ScreenshotMosaic.Scope)
        case toggleBackgroundRemoval
        case undo, redo, cancel, save, copy, scrollCapture
        /// Recognize the text, translate it or ask the AI about the image.
        case followUp(ScreenshotFollowUp)
        /// Keep the screenshot above other windows.
        case pin
        case copyAndSave
        case record
        case toggleMoreMenu
        case toggleSensitivePanel
        case toggleToolbarPlacement
        case resetStyles
        /// The grip is dragged by `translation` since the drag began; `ended` when it is let go.
        case dragToolbar(CGSize, ended: Bool)
    }

    var state = State()
    var onAction: ((Action) -> Void)?

    func perform(_ action: Action) {
        onAction?(action)
    }

    static func symbol(for tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .callout: "text.bubble"
        case .mosaic: "checkerboard.rectangle"
        }
    }

    static func symbol(for effect: ScreenshotMosaic.Effect) -> String {
        switch effect {
        case .pixelate: "square.grid.3x3.fill"
        case .blur: "drop.fill"
        case .solid: "square.fill"
        }
    }

    static func symbol(for shape: ScreenshotAnnotationEditor.MosaicShape) -> String {
        switch shape {
        case .rect: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .brush: "paintbrush.pointed"
        }
    }

    static func symbol(for fill: ScreenshotAnnotationStyle.Fill) -> String {
        switch fill {
        case .stroke: "square"
        case .soft: "square.lefthalf.filled"
        case .solid: "square.fill"
        }
    }

    static func symbol(for dash: ScreenshotAnnotationStyle.Dash) -> String {
        switch dash {
        case .solid: "minus"
        case .dashed: "ellipsis"
        }
    }

    static func symbol(for head: ScreenshotAnnotationStyle.ArrowHead) -> String {
        switch head {
        case .open: "arrow.right"
        case .filled: "arrowtriangle.right.fill"
        case .double: "arrow.left.and.right"
        }
    }

    static func symbol(for path: ScreenshotAnnotationStyle.ArrowPath) -> String {
        switch path {
        case .straight: "line.diagonal"
        case .curve: "arrow.turn.up.right"
        case .elbow: "arrow.turn.right.up"
        }
    }

    static func symbol(for anchor: ScreenshotAnnotationStyle.CalloutAnchor) -> String {
        switch anchor {
        case .dot: "smallcircle.filled.circle"
        case .arrow: "arrow.up.left"
        case .plain: "line.diagonal"
        }
    }

    static func symbol(for shape: ScreenshotAnnotationStyle.CounterShape) -> String {
        switch shape {
        case .circle: "circle.fill"
        case .bubble: "bubble.left.fill"
        }
    }

    /// How a counter labelled this way reads: "1 2 3" or "A B C".
    static func sample(for label: ScreenshotAnnotationStyle.CounterLabel) -> String {
        (1 ... 3).map { ScreenshotAnnotation.counterLabel($0, as: label) }.joined(separator: " ")
    }

    /// "Rectangle  R"
    static func help(for tool: ScreenshotAnnotationTool) -> String {
        "\(L("screenshot.tool.\(tool.rawValue)"))  \(tool.shortcut)"
    }

    /// "Red  1" for a preset, the hex value for a picked color.
    static func help(for color: ScreenshotAnnotationStyle.Color) -> String {
        guard let name = color.presetName,
              let index = ScreenshotAnnotationStyle.Color.presets.firstIndex(of: color) else { return color.hex }
        return "\(L("screenshot.color.\(name)"))  \((index + 1) % 10)"
    }

    /// The caption of the size slider: font size for text, size for counters, line width for the rest.
    static func sizeCaption(for tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .text, .callout: L("screenshot.edit.fontSize")
        case .counter: L("screenshot.edit.counterSize")
        default: L("screenshot.edit.size")
        }
    }
}

/// Hosts the toolbar with room around it for its shadow; presses on that margin fall
/// through to the overlay, so the region's handles next to the toolbar still work.
final class ScreenshotToolbarHostingView: NSHostingView<AnyView> {
    var hitInset: CGFloat = 0
    /// The state the root view was built from.
    var shownState: ScreenshotEditorToolbarModel.State?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.insetBy(dx: hitInset, dy: hitInset).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// The editing toolbar under the region, styled like the launcher's glass controls.
// swiftlint:disable:next type_body_length
struct ScreenshotEditorToolbar: View {
    let state: ScreenshotEditorToolbarModel.State
    let perform: (ScreenshotEditorToolbarModel.Action) -> Void

    static let barHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 6
    static let sliderWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            mainBar
            if let notice = state.isRemovingBackground ? "screenshot.background.processing" : state.backgroundNoticeKey {
                HStack(spacing: 6) {
                    if state.isRemovingBackground { ProgressView().controlSize(.small) }
                    Text(L(notice))
                        .font(.system(size: 12))
                }
                .padding(8)
                .background(glass(cornerRadius: 10))
            }
            if state.showsOptions {
                optionsBar
            }
            if state.showsOptions, state.showsColorPanel {
                colorPanel
            }
            if state.showsMoreMenu {
                // As wide as its rows, under the More button at the right end.
                moreMenu
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .fixedSize()
    }

    private var mainBar: some View {
        HStack(spacing: 2) {
            ForEach(ScreenshotAnnotationTool.allCases, id: \.self) { tool in
                iconButton(ScreenshotEditorToolbarModel.symbol(for: tool),
                           help: ScreenshotEditorToolbarModel.help(for: tool),
                           isOn: state.tool == tool) { perform(.tool(tool)) }
            }
            if state.showsScrollCapture || state.showsPin {
                separator
            }
            if state.showsScrollCapture {
                iconButton("rectangle.expand.vertical", help: "\(L("screenshot.tool.scroll"))  S",
                           isEnabled: state.canScrollCapture) { perform(.scrollCapture) }
                iconButton("record.circle", help: L("recording.title"),
                           isEnabled: state.canScrollCapture) { perform(.record) }
                    .accessibilityLabel(L("recording.title"))
                    .accessibilityIdentifier("screenshot.record")
            }
            if state.showsBackgroundRemoval {
                iconButton("wand.and.stars",
                           help: L(!state.supportsBackgroundRemoval ? "screenshot.background.unsupported" :
                                   state.isRemovingBackground ? "screenshot.background.cancel" :
                                   state.hasRemovedBackground ? "screenshot.background.restore" : "screenshot.background.remove"),
                           isOn: state.hasRemovedBackground || state.isRemovingBackground,
                           isEnabled: state.supportsBackgroundRemoval) { perform(.toggleBackgroundRemoval) }
                    .accessibilityLabel(L(state.hasRemovedBackground ? "screenshot.background.restore" : "screenshot.background.remove"))
                    .accessibilityIdentifier("screenshot.removeBackground")
            }
            if state.showsPin {
                iconButton("pin", help: "\(L("screenshot.tool.pin"))  F") { perform(.pin) }
                    .accessibilityIdentifier("screenshot.pin")
            }
            separator
            iconButton("arrow.uturn.backward", help: "\(L("screenshot.edit.undo"))  ⌘Z", isEnabled: state.canUndo) {
                perform(.undo)
            }
            iconButton("arrow.uturn.forward", help: "\(L("screenshot.edit.redo"))  ⇧⌘Z", isEnabled: state.canRedo) {
                perform(.redo)
            }
            separator
            ForEach(ScreenshotFollowUp.allCases, id: \.self) { followUp in
                followUpButton(followUp)
            }
            separator
            iconButton("square.and.arrow.down", help: "\(L("screenshot.edit.save"))  ⌘S") { perform(.save) }
            iconButton("ellipsis", help: L("screenshot.edit.more"), isOn: state.showsMoreMenu) {
                perform(.toggleMoreMenu)
            }
            .accessibilityIdentifier("screenshot.more")
            separator
            iconButton("xmark", help: "\(L("screenshot.edit.cancel"))  esc", tint: .red) { perform(.cancel) }
                .accessibilityLabel(L("screenshot.edit.cancel"))
                .accessibilityIdentifier("screenshot.cancel")
            iconButton("checkmark", help: "\(L("screenshot.edit.copy"))  ↩", tint: .green) { perform(.copy) }
                .accessibilityLabel(L("screenshot.edit.copy"))
                .accessibilityIdentifier("screenshot.copy")
            if state.showsPin {
                grip
            }
        }
        .padding(4)
        .background(glass(cornerRadius: 12))
    }

    /// Drags the toolbar out of the way; the drag is measured on screen, so it holds while the toolbar moves.
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(.degrees(90))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { perform(.dragToolbar($0.translation, ended: false)) }
                .onEnded { perform(.dragToolbar($0.translation, ended: true)) })
            .help(L("screenshot.edit.dragToolbar"))
    }

    /// Less used actions, as a short list under the toolbar.
    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            menuRow("square.and.arrow.down.on.square", L("screenshot.more.copyAndSave"), shortcut: "⌥↩") {
                perform(.copyAndSave)
            }
            if state.canShowSensitivePanel {
                menuRow("checkmark.shield", L("screenshot.more.sensitive"),
                        shortcut: state.showsSensitivePanel ? "✓" : "") { perform(.toggleSensitivePanel) }
            }
            if state.showsPin {
                menuRow(state.prefersToolbarAbove ? "dock.arrow.down.rectangle" : "dock.arrow.up.rectangle",
                        L(state.prefersToolbarAbove ? "screenshot.more.toolbarBelow" : "screenshot.more.toolbarAbove"))
                {
                    perform(.toggleToolbarPlacement)
                }
            }
            menuRow("arrow.counterclockwise", L("screenshot.more.resetStyles")) { perform(.resetStyles) }
        }
        .padding(5)
        .frame(minWidth: 220, alignment: .leading)
        .background(glass(cornerRadius: 10))
    }

    private func menuRow(_ symbol: String, _ title: String, shortcut: String = "",
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 12.5)).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var optionsBar: some View {
        HStack(spacing: 6) {
            if state.showsColor {
                colorButton
                separator
            }
            if state.showsMosaicOptions {
                mosaicOptions
                if let key = state.mosaicPreparation.noticeKey {
                    Text(L(key)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: 150).fixedSize(horizontal: false, vertical: true)
                }
            } else if let tool = state.optionsTool {
                shapeOptions(for: tool)
                toolOptions(for: tool)
                sizeSlider(for: tool)
                if tool == .rect {
                    slider(value: state.style.cornerRadius, in: ScreenshotAnnotationStyle.cornerRadiusRange,
                           caption: L("screenshot.edit.cornerRadius")) { perform(.cornerRadius($0.rounded())) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(glass(cornerRadius: 10))
    }

    /// Fill and dash for shapes, dash for lines; nothing for the other tools.
    @ViewBuilder
    private func shapeOptions(for tool: ScreenshotAnnotationTool) -> some View {
        if tool == .rect || tool == .ellipse {
            segment {
                ForEach(ScreenshotAnnotationStyle.Fill.allCases, id: \.self) { fill in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: fill),
                                 help: L("screenshot.fill.\(fill.rawValue)"),
                                 isOn: state.style.fill == fill) { perform(.fill(fill)) }
                }
            }
        }
        if tool == .rect || tool == .ellipse || tool == .line {
            segment {
                ForEach(ScreenshotAnnotationStyle.Dash.allCases, id: \.self) { dash in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: dash),
                                 help: L("screenshot.dash.\(dash.rawValue)"),
                                 isOn: state.style.dash == dash) { perform(.dash(dash)) }
                }
            }
            separator
        }
    }

    /// Arrow heads and paths, pen smoothing, highlighter strokes, text fonts and counter labels.
    @ViewBuilder
    private func toolOptions(for tool: ScreenshotAnnotationTool) -> some View {
        let style = state.style
        switch tool {
        case .arrow:
            segment {
                ForEach(ScreenshotAnnotationStyle.ArrowHead.allCases, id: \.self) { head in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: head),
                                 help: L("screenshot.arrow.head.\(head.rawValue)"),
                                 isOn: style.arrowHead == head) { perform(.arrowHead(head)) }
                }
            }
            segment {
                ForEach(ScreenshotAnnotationStyle.ArrowPath.allCases, id: \.self) { path in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: path),
                                 help: L("screenshot.arrow.path.\(path.rawValue)"),
                                 isOn: style.arrowPath == path) { perform(.arrowPath(path)) }
                }
            }
            toggle(L("screenshot.arrow.outline"), isOn: style.outlined) { perform(.outlined(!style.outlined)) }
            separator
        case .pen:
            segment {
                textOption(L("screenshot.pen.smooth"), isOn: style.smoothed) { perform(.smoothed(true)) }
                textOption(L("screenshot.pen.raw"), isOn: !style.smoothed) { perform(.smoothed(false)) }
            }
            separator
        case .highlighter:
            segment {
                ForEach(ScreenshotAnnotationStyle.HighlighterMode.allCases, id: \.self) { mode in
                    textOption(L("screenshot.highlighter.\(mode.rawValue)"), isOn: style.highlighterMode == mode) {
                        perform(.highlighterMode(mode))
                    }
                }
            }
            segment {
                ForEach(ScreenshotAnnotationStyle.HighlighterTip.allCases, id: \.self) { tip in
                    textOption(L("screenshot.highlighter.tip.\(tip.rawValue)"), isOn: style.highlighterTip == tip) {
                        perform(.highlighterTip(tip))
                    }
                }
            }
            separator
        case .callout:
            caption(L("screenshot.callout.anchor"))
            segment {
                ForEach(ScreenshotAnnotationStyle.CalloutAnchor.allCases, id: \.self) { anchor in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: anchor),
                                 help: L("screenshot.callout.anchor.\(anchor.rawValue)"),
                                 isOn: style.calloutAnchor == anchor) { perform(.calloutAnchor(anchor)) }
                }
            }
            segment {
                ForEach(ScreenshotAnnotationStyle.TextStyle.allCases, id: \.self) { textStyle in
                    textStyleButton(textStyle, isOn: style.textStyle == textStyle)
                }
            }
            separator
        case .text:
            segment {
                ForEach(ScreenshotAnnotationStyle.TextFont.allCases, id: \.self) { font in
                    fontButton(font, isOn: style.font == font)
                }
            }
            segment {
                ForEach(ScreenshotAnnotationStyle.TextStyle.allCases, id: \.self) { textStyle in
                    textStyleButton(textStyle, isOn: style.textStyle == textStyle)
                }
            }
            separator
        case .counter:
            segment {
                ForEach(ScreenshotAnnotationStyle.CounterLabel.allCases, id: \.self) { label in
                    textOption(ScreenshotEditorToolbarModel.sample(for: label), isOn: style.counterLabel == label) {
                        perform(.counterLabel(label))
                    }
                }
            }
            segment {
                ForEach(ScreenshotAnnotationStyle.CounterShape.allCases, id: \.self) { shape in
                    optionButton(ScreenshotEditorToolbarModel.symbol(for: shape),
                                 help: L("screenshot.counter.shape.\(shape.rawValue)"),
                                 isOn: style.counterShape == shape) { perform(.counterShape(shape)) }
                }
            }
            counterStepper
            separator
        default:
            EmptyView()
        }
    }

    /// The first counter's number (or letter), one up or down.
    private var counterStepper: some View {
        let range = ScreenshotAnnotationStyle.counterStartRange
        return HStack(spacing: 2) {
            caption(L("screenshot.counter.start"))
            optionButton("minus", help: L("screenshot.counter.start"), isOn: false) {
                perform(.counterStart(state.counterStart - 1))
            }
            .disabled(state.counterStart <= range.lowerBound)
            Text(ScreenshotAnnotation.counterLabel(state.counterStart, as: state.style.counterLabel))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 20)
            optionButton("plus", help: L("screenshot.counter.start"), isOn: false) {
                perform(.counterStart(state.counterStart + 1))
            }
            .disabled(state.counterStart >= range.upperBound)
        }
    }

    private func fontButton(_ font: ScreenshotAnnotationStyle.TextFont, isOn: Bool) -> some View {
        Button { perform(.font(font)) } label: {
            Text("Aa")
                .font(Font(ScreenshotAnnotation.font(size: 12, family: font) as CTFont))
                .foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AskTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("screenshot.text.font.\(font.rawValue)"))
    }

    private func textStyleButton(_ textStyle: ScreenshotAnnotationStyle.TextStyle, isOn: Bool) -> some View {
        Button { perform(.textStyle(textStyle)) } label: {
            Group {
                switch textStyle {
                case .plain:
                    Text("Aa").foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                case .background:
                    Text("Aa").foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? AskTheme.accent : Color.secondary))
                case .outline:
                    Text("Aa").foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                        .padding(.horizontal, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isOn ? AskTheme.accent : Color.secondary, lineWidth: 1))
                }
            }
            .font(.system(size: 11, weight: .bold))
            .frame(width: 28, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AskTheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("screenshot.text.style.\(textStyle.rawValue)"))
    }

    private func textOption(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AskTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Capsule()
                    .fill(isOn ? AskTheme.accent : AskTheme.pressFill)
                    .frame(width: 24, height: 14)
                    .overlay(Circle().fill(.white).frame(width: 10, height: 10).offset(x: isOn ? 5 : -5))
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mosaicOptions: some View {
        ForEach(ScreenshotAnnotationEditor.MosaicShape.allCases, id: \.self) { shape in
            optionButton(ScreenshotEditorToolbarModel.symbol(for: shape),
                         help: L("screenshot.mosaic.shape.\(shape.rawValue)"),
                         isOn: state.mosaicShape == shape) { perform(.mosaicShape(shape)) }
        }
        if state.mosaicShape != .brush {
            caption(L("screenshot.mosaic.scope"))
            segment {
                ForEach(ScreenshotMosaic.Scope.allCases, id: \.self) { scope in
                    textOption(L("screenshot.mosaic.scope.\(scope.rawValue)"), isOn: state.mosaicScope == scope) {
                        perform(.mosaicScope(scope))
                    }
                }
            }
        }
        separator
        ForEach(ScreenshotMosaic.Effect.allCases, id: \.self) { effect in
            optionButton(ScreenshotEditorToolbarModel.symbol(for: effect),
                         help: L("screenshot.mosaic.effect.\(effect.rawValue)"),
                         isOn: state.mosaicEffect == effect) { perform(.mosaicEffect(effect)) }
        }
        separator
        caption(L("screenshot.mosaic.strength"))
        ForEach(ScreenshotMosaic.Strength.allCases, id: \.self) { strength in
            strengthButton(strength)
        }
        if state.mosaicShape == .brush {
            separator
            sizeSlider(for: .mosaic)
        }
    }

    private func sizeSlider(for tool: ScreenshotAnnotationTool) -> some View {
        slider(value: state.size, in: tool.sizeRange,
               caption: ScreenshotEditorToolbarModel.sizeCaption(for: tool)) { perform(.size($0.rounded())) }
    }

    /// The color button: the current color, with a ring while the panel is open.
    private var colorButton: some View {
        let isOn = state.showsColorPanel
        return Button { perform(.toggleColorPanel) } label: {
            Circle()
                .fill(Color(cgColor: state.style.color.cgColor()))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(isOn ? AskTheme.accent : Color.primary.opacity(0.25), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("screenshot.edit.color"))
        .accessibilityIdentifier("screenshot.color.button")
    }

    /// The presets (1–0), the colors used lately, the eyedropper and the opacity.
    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(ScreenshotAnnotationStyle.Color.presets.enumerated()), id: \.offset) { _, color in
                    swatch(color, diameter: 18)
                }
            }
            HStack(spacing: 6) {
                caption(L("screenshot.color.recent"))
                if state.recentColors.isEmpty {
                    caption("—")
                }
                ForEach(Array(state.recentColors.enumerated()), id: \.offset) { _, color in
                    swatch(color, diameter: 14)
                }
                Spacer(minLength: 8)
                Button { perform(.pickColor) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eyedropper").font(.system(size: 11, weight: .medium))
                        Text(L("screenshot.color.pick")).font(.system(size: 12)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(state.isPickingColor ? AskTheme.accent : Color.primary.opacity(0.75))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(state.isPickingColor ? AskTheme.accentSoft : AskTheme.pressFill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("screenshot.color.pick")
            }
            slider(value: state.style.opacity, in: ScreenshotAnnotationStyle.opacityRange,
                   caption: L("screenshot.edit.opacity"), label: "\(Int((state.style.opacity * 100).rounded()))%") {
                perform(.opacity(($0 * 20).rounded() / 20))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(glass(cornerRadius: 10))
    }

    private func swatch(_ color: ScreenshotAnnotationStyle.Color, diameter: CGFloat) -> some View {
        let isOn = state.style.color == color
        return Button { perform(.color(color)) } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor()))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .padding(2)
                .overlay(Circle().strokeBorder(isOn ? Color.primary : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(ScreenshotEditorToolbarModel.help(for: color))
    }

    /// A compact slider with its caption and value; a drag reports its start and end, so it undoes in one step.
    private func slider(value: CGFloat, in range: ClosedRange<CGFloat>, caption text: String, label: String? = nil,
                        set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 5) {
            caption(text)
            Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                   in: Double(range.lowerBound) ... Double(range.upperBound)) { editing in
                perform(.styleChange(began: editing))
            }
            .controlSize(.mini)
            .frame(width: Self.sliderWidth)
            Text(label ?? "\(Int(value.rounded()))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
        }
    }

    private func segment(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 2) { content() }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(AskTheme.pressFill.opacity(0.6)))
    }

    private func strengthButton(_ strength: ScreenshotMosaic.Strength) -> some View {
        let isOn = state.mosaicStrength == strength
        return Button { perform(.mosaicStrength(strength)) } label: {
            Text(L("screenshot.mosaic.strength.\(["low", "medium", "high"][strength.rawValue])"))
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AskTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, help: String, isOn: Bool = false, isEnabled: Bool = true,
                            tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? (isOn ? AskTheme.accent : Color.primary.opacity(0.75)))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? AskTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
    }

    /// "Recognize text" and "Translate" as icons, "Ask AI" with its name, as in the design.
    @ViewBuilder
    private func followUpButton(_ followUp: ScreenshotFollowUp) -> some View {
        if followUp == .askAI {
            Button { perform(.followUp(followUp)) } label: {
                HStack(spacing: 4) {
                    Image(systemName: followUp.symbol).font(.system(size: 13, weight: .medium))
                    Text(followUp.title).font(.system(size: 12.5)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(AskTheme.accent)
                .padding(.horizontal, 7)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(followUp.title)
            .accessibilityIdentifier("screenshot.followUp.\(followUp.rawValue)")
        } else {
            iconButton(followUp.symbol, help: followUp.title) { perform(.followUp(followUp)) }
                .accessibilityIdentifier("screenshot.followUp.\(followUp.rawValue)")
        }
    }

    private func optionButton(_ symbol: String, help: String, isOn: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? AskTheme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AskTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var separator: some View {
        Rectangle().fill(AskTheme.border).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    private func glass(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AskTheme.glassFill.opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(AskTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}
