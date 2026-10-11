// swiftlint:disable file_length
import AppKit
import SwiftUI

/// What the editor toolbar shows and what its buttons ask for. The overlay rebuilds the
/// toolbar from `state` whenever it changes, so its size is known at once for placement.
@MainActor
final class ScreenshotEditorToolbarModel {
    struct State: Equatable {
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
        var recentColors: [ScreenshotAnnotationStyle.Color] = []
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

        init() {}

        /// The toolbar for an editor's current state.
        init(editor: ScreenshotAnnotationEditor, showsColorPanel: Bool, isPickingColor: Bool,
             showsScrollCapture: Bool = true, canScrollCapture: Bool = true) {
            let mosaic = editor.selected?.mosaic
            tool = editor.tool
            optionsTool = editor.optionsTool
            style = editor.shownStyle ?? editor.style
            size = editor.shownSize ?? style.size
            mosaicEffect = mosaic?.effect ?? editor.mosaicEffect
            mosaicStrength = mosaic?.strength ?? editor.mosaicStrength
            mosaicShape = mosaic.map { if case .brush = $0.shape { .brush } else { .rect } } ?? editor.mosaicShape
            recentColors = editor.toolStyles.recentColors
            canUndo = editor.document.canUndo
            canRedo = editor.document.canRedo
            showsOptions = editor.optionsTool != nil
            showsMosaicOptions = editor.showsMosaicOptions
            showsColor = editor.offersColor
            self.showsColorPanel = showsColorPanel && editor.offersColor
            self.isPickingColor = isPickingColor
            self.showsScrollCapture = showsScrollCapture
            self.canScrollCapture = canScrollCapture
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
        case undo, redo, cancel, save, copy, scrollCapture
        /// Recognize the text, translate it or ask the AI about the image.
        case followUp(ScreenshotFollowUp)
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
        case .text: L("screenshot.edit.fontSize")
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
struct ScreenshotEditorToolbar: View {
    let state: ScreenshotEditorToolbarModel.State
    let perform: (ScreenshotEditorToolbarModel.Action) -> Void

    static let barHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 6
    static let sliderWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            mainBar
            if state.showsOptions {
                optionsBar
            }
            if state.showsOptions, state.showsColorPanel {
                colorPanel
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
            if state.showsScrollCapture {
                separator
                iconButton("rectangle.expand.vertical", help: "\(L("screenshot.tool.scroll"))  S",
                           isEnabled: state.canScrollCapture) { perform(.scrollCapture) }
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
            iconButton("xmark", help: "\(L("screenshot.edit.cancel"))  esc") { perform(.cancel) }
            iconButton("square.and.arrow.down", help: "\(L("screenshot.edit.save"))  ⌘S") { perform(.save) }
            Button { perform(.copy) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text(L("screenshot.edit.copy")).font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(AskTheme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(L("screenshot.edit.copy"))  ↩")
        }
        .padding(4)
        .background(glass(cornerRadius: 12))
    }

    @ViewBuilder
    var optionsBar: some View {
        HStack(spacing: 6) {
            if state.showsColor {
                colorButton
                separator
            }
            if state.showsMosaicOptions {
                mosaicOptions
            } else if let tool = state.optionsTool {
                shapeOptions(for: tool)
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

    @ViewBuilder
    private var mosaicOptions: some View {
        ForEach(ScreenshotAnnotationEditor.MosaicShape.allCases, id: \.self) { shape in
            optionButton(ScreenshotEditorToolbarModel.symbol(for: shape),
                         help: L("screenshot.mosaic.shape.\(shape.rawValue)"),
                         isOn: state.mosaicShape == shape) { perform(.mosaicShape(shape)) }
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
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
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

    private func segment<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
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
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? AskTheme.accent : Color.primary.opacity(0.75))
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
