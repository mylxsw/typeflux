import AppKit
import SwiftUI

/// What the editor toolbar shows and what its buttons ask for. The overlay rebuilds the
/// toolbar from `state` whenever it changes, so its size is known at once for placement.
@MainActor
final class ScreenshotEditorToolbarModel {
    struct State: Equatable {
        var tool: ScreenshotAnnotationTool?
        var style = ScreenshotAnnotationStyle()
        var mosaicEffect: ScreenshotMosaic.Effect = .pixelate
        var mosaicStrength: ScreenshotMosaic.Strength = .medium
        var mosaicShape: ScreenshotAnnotationEditor.MosaicShape = .rect
        var canUndo = false
        var canRedo = false
        /// A tool is picked or an annotation selected: the second row shows its options.
        var showsOptions = false
        var showsMosaicOptions = false
    }

    enum Action: Equatable {
        case tool(ScreenshotAnnotationTool)
        case color(ScreenshotAnnotationStyle.Color)
        case width(ScreenshotAnnotationStyle.Width)
        case mosaicEffect(ScreenshotMosaic.Effect)
        case mosaicStrength(ScreenshotMosaic.Strength)
        case mosaicShape(ScreenshotAnnotationEditor.MosaicShape)
        case undo, redo, cancel, save, copy
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

    /// "Rectangle  R"
    static func help(for tool: ScreenshotAnnotationTool) -> String {
        "\(L("screenshot.tool.\(tool.rawValue)"))  \(tool.shortcut)"
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

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            mainBar
            if state.showsOptions {
                optionsBar
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
            separator
            iconButton("arrow.uturn.backward", help: "\(L("screenshot.edit.undo"))  ⌘Z", isEnabled: state.canUndo) {
                perform(.undo)
            }
            iconButton("arrow.uturn.forward", help: "\(L("screenshot.edit.redo"))  ⇧⌘Z", isEnabled: state.canRedo) {
                perform(.redo)
            }
            separator
            iconButton("xmark", help: "\(L("screenshot.edit.cancel"))  esc") { perform(.cancel) }
            iconButton("square.and.arrow.down", help: "\(L("screenshot.edit.save"))  ⌘S") { perform(.save) }
            Button { perform(.copy) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text(L("screenshot.edit.copy")).font(.system(size: 12.5, weight: .semibold))
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
    private var optionsBar: some View {
        HStack(spacing: 6) {
            if state.showsMosaicOptions {
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
                    widthButtons
                }
            } else {
                caption(L("screenshot.edit.color"))
                ForEach(ScreenshotAnnotationStyle.Color.allCases, id: \.self) { color in
                    swatch(color)
                }
                separator
                caption(L("screenshot.edit.size"))
                widthButtons
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(glass(cornerRadius: 10))
    }

    private var widthButtons: some View {
        ForEach(ScreenshotAnnotationStyle.Width.allCases, id: \.self) { width in
            Button { perform(.width(width)) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary)
                    .frame(width: 12, height: CGFloat(2 + width.rawValue * 2))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(state.style.width == width ? AskTheme.pressFill : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("screenshot.width.\(["thin", "medium", "thick"][width.rawValue])"))
        }
    }

    private func swatch(_ color: ScreenshotAnnotationStyle.Color) -> some View {
        let rgb = color.rgb
        let isOn = state.style.color == color
        return Button { perform(.color(color)) } label: {
            Circle()
                .fill(Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                .frame(width: 16, height: 16)
                .padding(2)
                .overlay(Circle().strokeBorder(isOn ? Color.primary : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("screenshot.color.\(color.rawValue)"))
    }

    private func strengthButton(_ strength: ScreenshotMosaic.Strength) -> some View {
        let isOn = state.mosaicStrength == strength
        return Button { perform(.mosaicStrength(strength)) } label: {
            Text(L("screenshot.mosaic.strength.\(["low", "medium", "high"][strength.rawValue])"))
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
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
