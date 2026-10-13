import AppKit
import SwiftUI

struct StudioInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TypefluxLogoBadge: View {
    enum BackgroundShape {
        case roundedSquare
        case circle
    }

    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat
    let symbolSize: CGFloat
    let backgroundShape: BackgroundShape
    let showsBorder: Bool

    init(
        size: CGFloat = 52,
        symbolSize: CGFloat = 26,
        backgroundShape: BackgroundShape = .circle,
        showsBorder: Bool = false
    ) {
        self.size = size
        self.symbolSize = symbolSize
        self.backgroundShape = backgroundShape
        self.showsBorder = showsBorder
    }

    var body: some View {
        ZStack {
            badgeBackground

            Image(systemName: "infinity")
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badgeBackground: some View {
        switch backgroundShape {
        case .roundedSquare:
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(badgeFill)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(borderColor, lineWidth: showsBorder ? 1 : 0)
                )
        case .circle:
            Circle()
                .fill(markFill)
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: showsBorder ? 1 : 0)
                )
        }
    }

    private var badgeFill: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.10)
        default:
            Color.black.opacity(0.08)
        }
    }

    private var symbolColor: Color {
        if backgroundShape == .circle {
            return markSymbolColor
        }

        return switch colorScheme {
        case .dark:
            Color.white
        default:
            Color.black
        }
    }

    private var markFill: Color {
        switch colorScheme {
        case .dark:
            Color.white
        default:
            Color.black
        }
    }

    private var markSymbolColor: Color {
        switch colorScheme {
        case .dark:
            Color.black
        default:
            Color.white
        }
    }

    private var borderColor: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.18)
        default:
            Color.black.opacity(0.14)
        }
    }
}

// MARK: - Floating Tooltip Panel

private final class TooltipFloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Stay above the statusBar-level overlay panel
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
private final class TooltipWindowController {
    static let shared = TooltipWindowController()

    private let panel = TooltipFloatingPanel()
    private var hostingView: NSHostingView<AnyView>?

    func show(text: String, screenFrame: NSRect, yOffset: CGFloat) {
        let tooltipView = AnyView(
            Text(text)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, TypefluxSpacing.regular.value(for: .classic))
                .padding(.vertical, TypefluxSpacing.small.value(for: .classic))
                .background(
                    RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: .classic), style: .continuous)
                        .fill(LegacyStudioPalette.tooltipBackground)
                )
                .fixedSize()
        )

        if let existing = hostingView {
            existing.rootView = tooltipView
        } else {
            let hosting = NSHostingView(rootView: tooltipView)
            panel.contentView = hosting
            hostingView = hosting
        }

        guard let hosting = hostingView else { return }
        let size = hosting.fittingSize

        // Match the old overlay tooltip behavior: yOffset controls how far the
        // tooltip's top edge sits above the anchor's top edge.
        var origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY + yOffset - size.height
        )

        // Clamp to the screen that contains the mouse
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        if let bounds = screen?.frame {
            origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
            if origin.y + size.height > bounds.maxY {
                origin.y = screenFrame.minY - yOffset
            }
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Invisible NSView that reports its screen-space frame via a callback.
private final class ScreenAnchorNSView: NSView {
    var onFrame: ((NSRect) -> Void)?

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    private func reportFrame() {
        guard let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        onFrame?(screenFrame)
    }
}

private struct ScreenFrameAnchor: NSViewRepresentable {
    let onFrame: (NSRect) -> Void

    func makeNSView(context _: Context) -> ScreenAnchorNSView {
        let view = ScreenAnchorNSView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: ScreenAnchorNSView, context _: Context) {
        nsView.onFrame = onFrame
    }
}

private struct StudioTooltipModifier: ViewModifier {
    let text: String
    var yOffset: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    let mouse = NSEvent.mouseLocation
                    // Build a zero-height anchor at the cursor position so the
                    // tooltip appears yOffset points above the cursor.
                    let anchor = NSRect(x: mouse.x - 16, y: mouse.y, width: 32, height: 0)
                    TooltipWindowController.shared.show(
                        text: text,
                        screenFrame: anchor,
                        yOffset: yOffset
                    )
                } else {
                    TooltipWindowController.shared.hide()
                }
            }
    }
}

extension View {
    func studioTooltip(_ text: String, yOffset: CGFloat = 10) -> some View {
        modifier(StudioTooltipModifier(text: text, yOffset: yOffset))
    }
}

typealias StudioRoundedVisualEffectView = RoundedVisualEffectView
typealias StudioVisualEffectBlur = VisualEffectBlur

private struct StudioLiquidGlassBackground<S: InsettableShape>: View {
    @Environment(\.liquidGlassIntensity) private var intensity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S
    let cornerRadius: CGFloat?
    let material: NSVisualEffectView.Material
    let tintOpacity: Double
    let scrimOpacity: Double
    let strokeOpacity: Double
    let interactive: Bool

    private var usesMaterial: Bool { style.usesGlass && !reduceTransparency && contrast != .increased }
    private var usesNativeGlass: Bool { usesMaterial && AskGlassMaterial.systemSupportsLiquidGlass }

    init(
        shape: S,
        cornerRadius: CGFloat? = nil,
        material: NSVisualEffectView.Material = .hudWindow,
        tintOpacity: Double = 0.96,
        scrimOpacity: Double = 0.96,
        strokeOpacity: Double = 1,
        interactive: Bool = false
    ) {
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.material = material
        self.tintOpacity = tintOpacity
        self.scrimOpacity = scrimOpacity
        self.strokeOpacity = strokeOpacity
        self.interactive = interactive
    }

    var body: some View {
        Group {
            if !usesMaterial {
                shape.fill(TypefluxColor.controlBackground.color)
            } else {
                #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        shape
                            .fill(Color.clear)
                            .glassEffect(
                                Glass.regular
                                    .interactive(interactive)
                                    .tint(LegacyStudioPalette.glassTint
                                        .opacity(intensity.nativeFrostOpacity(tintOpacity))),
                                in: shape
                            )
                            .overlay(shape.fill(AskWindowBackdrop.base(dark: colorScheme == .dark)
                                    .opacity(intensity.extraTintOpacity)))

                    } else {
                        fallbackBackground
                    }
                #else
                    fallbackBackground
                #endif
            }
        }
        .clipShape(shape)
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            LegacyStudioPalette.glassStrokeHighlight.opacity(strokeOpacity),
                            LegacyStudioPalette.glassStrokeHighlight.opacity(strokeOpacity * 0.28),
                            LegacyStudioPalette.glassStrokeShadow.opacity(0.50)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .opacity(usesMaterial && !usesNativeGlass ? 1 : 0)
        )
        .overlay(
            shape
                .inset(by: 1 + 0.5)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            LegacyStudioPalette.glassInnerHighlight,
                            Color.clear,
                            LegacyStudioPalette.glassInnerHighlight.opacity(0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
                .blendMode(.screen)
                .opacity(usesMaterial && !usesNativeGlass ? 1 : 0)
        )
    }

    private var fallbackBackground: some View {
        ZStack {
            StudioVisualEffectBlur(
                material: material,
                blendingMode: .withinWindow,
                cornerRadius: cornerRadius
            )
            .allowsHitTesting(false)

            shape
                .fill(LegacyStudioPalette.glassScrim.opacity(intensity.legacyFrostOpacity(scrimOpacity)))
            shape
                .fill(LegacyStudioPalette.glassTint.opacity(intensity.legacyFrostOpacity(tintOpacity)))
        }
    }
}

struct StudioButtonChromeModifier: ViewModifier {
    let variant: StudioButton.Variant
    let isDisabled: Bool
    let isLoading: Bool
    let isPressed: Bool
    let minWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    /// Light primary buttons are solid accent, #1D4ED8 under the pointer; dark keeps its gradient.
    static func solidPrimaryFill(dark: Bool, hovering: Bool) -> Color? {
        guard !dark else { return nil }
        return hovering ? TypefluxColor.accent.color : TypefluxColor.accent.color
    }

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .frame(minWidth: minWidth)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(overlay)
            .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: .classic), style: .continuous))
            .contentShape(RoundedRectangle(
                cornerRadius: TypefluxRadius.popover.value(for: .classic),
                style: .continuous
            ))
            .scaleEffect(isPressed ? 0.985 : 1)
            .opacity(opacity)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: isLoading)
    }

    @ViewBuilder
    private var background: some View {
        let buttonShape = RoundedRectangle(
            cornerRadius: TypefluxRadius.popover.value(for: .classic),
            style: .continuous
        )

        switch variant {
        case .primary where Self.solidPrimaryFill(dark: colorScheme == .dark, hovering: isHovering || isPressed) != nil:
            buttonShape
                .fill(Self
                    .solidPrimaryFill(dark: colorScheme == .dark, hovering: isHovering || isPressed) ?? TypefluxColor
                    .accent.color)
                .shadow(color: TypefluxColor.accent.color.opacity(0.18), radius: 8, x: 0, y: 5)
        case .primary:
            buttonShape
                .fill(
                    LinearGradient(
                        colors: [
                            TypefluxColor.accent.color.opacity(0.92),
                            TypefluxColor.accent.color
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .brightness(isPressed ? -0.06 : (isLoading ? -0.03 : 0))
                .shadow(color: TypefluxColor.accent.color.opacity(0.18), radius: 8, x: 0, y: 5)
        case .secondary:
            ZStack {
                StudioLiquidGlassBackground(
                    shape: buttonShape,
                    cornerRadius: TypefluxRadius.popover.value(for: .classic),
                    tintOpacity: isPressed ? 0.72 : 0.28,
                    scrimOpacity: isPressed ? 0.76 : 0.56,
                    interactive: true
                )

                buttonShape
                    .fill(isPressed ? TypefluxColor.selection.color.opacity(0.12) : TypefluxColor.controlBackground
                        .color)
                    .opacity(style.usesGlass && !reduceTransparency && contrast != .increased
                        ? (isPressed ? 0.22 : 0.08) : 1)
            }
            .brightness(isPressed ? -0.03 : (isLoading ? -0.015 : 0))
        case .ghost:
            buttonShape
                .fill(isPressed ? TypefluxColor.controlBackground
                    .color : (isLoading ? TypefluxColor.controlBackground.color.opacity(0.62) : Color.clear))
        }
    }

    private var overlay: some View {
        RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: .classic), style: .continuous)
            .stroke(borderColor, lineWidth: borderWidth)
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            .white
        case .secondary:
            TypefluxColor.label.color
        case .ghost:
            TypefluxColor.secondaryLabel.color
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            Color.clear
        case .secondary, .ghost:
            TypefluxColor.separator.color.opacity(isPressed || isLoading ? 0.82 : 1)
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .ghost:
            isPressed || isLoading ? 1 : 0
        case .primary, .secondary:
            1
        }
    }

    private var opacity: Double {
        if isDisabled { return 0.72 }
        return 1
    }
}

private struct StudioButtonChrome<Label: View>: View {
    let variant: StudioButton.Variant
    let isDisabled: Bool
    let isLoading: Bool
    let minWidth: CGFloat?
    let action: () -> Void
    let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        Button {
            isPressed = true
            action()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                isPressed = false
            }
        } label: {
            label()
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(StudioInteractiveButtonStyle())
        .modifier(
            StudioButtonChromeModifier(
                variant: variant,
                isDisabled: isDisabled || isLoading,
                isLoading: isLoading,
                isPressed: isPressed,
                minWidth: minWidth
            )
        )
    }
}

struct StudioGlassBackground: View {
    @Environment(\.liquidGlassIntensity) private var intensity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.interfaceStyle) private var style

    let tintOpacity: Double

    var body: some View {
        if !style.usesGlass || reduceTransparency || contrast == .increased {
            TypefluxColor.windowBackground.color
                .background(AskWindowBackdrop.base(dark: colorScheme == .dark))
        } else if colorScheme == .dark {
            ZStack {
                StudioVisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow, cornerRadius: nil)

                TypefluxColor.windowBackground.color
                    .opacity(intensity.nativeFrostOpacity(tintOpacity))
                AskWindowBackdrop.base(dark: true).opacity(intensity.extraTintOpacity)
            }
        } else {
            ZStack {
                StudioVisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow, cornerRadius: nil)

                TypefluxColor.windowBackground.color
                    .opacity(intensity.nativeFrostOpacity(tintOpacity))

                LinearGradient(
                    colors: [
                        LegacyStudioPalette.windowHighlight.opacity(0.92),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
                AskWindowBackdrop.base(dark: false).opacity(intensity.extraTintOpacity)
            }
        }
    }
}

struct StudioSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
    }
}

struct StudioCard<Content: View>: View {
    enum Texture {
        case standard
        case softWaves
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style

    var padding: CGFloat = TypefluxSpacing.section.value(for: .classic)
    var showsShadow: Bool = false
    var isHighlighted: Bool = false
    var isDimmed: Bool = false
    var texture: Texture = .standard
    /// Suppress the surface and outline without changing content spacing.
    var showsChrome: Bool = true
    let content: Content

    init(
        padding: CGFloat = TypefluxSpacing.section.value(for: .classic),
        showsShadow: Bool = false,
        isHighlighted: Bool = false,
        isDimmed: Bool = false,
        texture: Texture = .standard,
        showsChrome: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.showsShadow = showsShadow
        self.isHighlighted = isHighlighted
        self.isDimmed = isDimmed
        self.texture = texture
        self.showsChrome = showsChrome
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TypefluxSpacing.large.value(for: .classic)) {
            content
        }
        .padding(padding)
        .background(
            ZStack {
                if showsChrome {
                    RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                        .fill(style.usesGlass ? TypefluxColor.contentBackground.color : AskClassic.card)
                    cardTextureOverlay

                    RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                        .fill(selectionOverlay)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                .stroke(
                    showsChrome ? cardBorderColor : .clear,
                    lineWidth: isHighlighted ? 1.5 : (usesLightGlassCard ? 1 : 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous))
        .shadow(
            color: LegacyStudioPalette.shadow
                .opacity(!showsChrome || !style
                    .usesGlass || usesLightGlassCard || !showsShadow ? 0 : (isHighlighted ? 0.20 : 0.16)),
            radius: isHighlighted ? 18 + 2 : 18,
            x: 0,
            y: isHighlighted ? 8 + 1 : 8
        )
    }

    /// Light Liquid Glass: a flat white card with a 1px hairline and no shadow.
    private var usesLightGlassCard: Bool {
        Self.usesLightGlassCard(glass: style.usesGlass, dark: colorScheme == .dark)
    }

    static func usesLightGlassCard(glass: Bool, dark: Bool) -> Bool {
        glass && !dark
    }

    private var selectionOverlay: Color {
        if isHighlighted {
            return TypefluxColor.accent.color.opacity(0.12).opacity(0.36)
        }

        if isDimmed {
            return TypefluxColor.controlBackground.color.opacity(0.38)
        }

        return Color.clear
    }

    private var cardBorderColor: Color {
        if isHighlighted {
            return TypefluxColor.accent.color.opacity(0.34)
        }

        return usesLightGlassCard ? TypefluxColor.separator.color : TypefluxColor.separator.color
    }

    private var cardTextureOverlay: some View {
        Group {
            if texture == .softWaves {
                softWaveTexture
            } else if colorScheme == .dark {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.clear,
                                TypefluxColor.accent.color.opacity(0.12).opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        TypefluxColor.separator.color.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            }
        }
    }

    private var softWaveTexture: some View {
        Group {
            if colorScheme == .dark {
                Color.clear
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let baseOpacity = 0.18
                    let accentOpacity = isHighlighted ? 0.18 : 0.08
                    let highlightOpacity = 0.18

                    ZStack {
                        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(baseOpacity),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Ellipse()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        TypefluxColor.accent.color.opacity(accentOpacity),
                                        Color.white.opacity(highlightOpacity),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: width * 1.12, height: height * 0.56)
                            .rotationEffect(.degrees(-17))
                            .offset(x: width * 0.32, y: -height * 0.26)
                            .blur(radius: 9)

                        Ellipse()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        Color.white.opacity(highlightOpacity * 0.72),
                                        TypefluxColor.accent.color.opacity(0.12).opacity(accentOpacity * 0.52),
                                        Color.clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: width * 1.08, height: height * 0.42)
                            .rotationEffect(.degrees(-17))
                            .offset(x: width * 0.18, y: height * 0.02)
                            .blur(radius: 12)

                        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        isHighlighted ? TypefluxColor.accent.color.opacity(0.12)
                                            .opacity(accentOpacity * 0.58) : Color
                                            .clear,
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct StudioButton: View {
    enum Variant {
        case primary
        case secondary
        case ghost
    }

    let title: String
    let systemImage: String?
    let variant: Variant
    var isDisabled: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        StudioButtonChrome(
            variant: variant,
            isDisabled: isDisabled,
            isLoading: isLoading,
            minWidth: variant == .ghost ? nil : 84,
            action: action
        ) {
            HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? .white : TypefluxColor.secondaryLabel.color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(.subheadline, weight: .semibold))
                }
                Text(title)
                    .font(.system(.body, weight: .semibold))
            }
            .padding(.horizontal, variant == .ghost ? 0 : TypefluxSpacing.large.value(for: .classic))
            .padding(.vertical, variant == .ghost ? 0 : 10)
            .contentShape(RoundedRectangle(
                cornerRadius: TypefluxRadius.popover.value(for: .classic),
                style: .continuous
            ))
        }
    }
}

struct StudioIconButton: View {
    let systemImage: String
    var variant: StudioButton.Variant = .ghost
    var isDisabled: Bool = false
    var isLoading: Bool = false
    var frame: CGFloat = 32
    let action: () -> Void

    var body: some View {
        StudioButtonChrome(
            variant: variant,
            isDisabled: isDisabled,
            isLoading: isLoading,
            minWidth: nil,
            action: action
        ) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? .white : TypefluxColor.secondaryLabel.color)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(.body, weight: .medium))
                }
            }
            .frame(width: frame, height: frame)
            .contentShape(RoundedRectangle(
                cornerRadius: TypefluxRadius.popover.value(for: .classic),
                style: .continuous
            ))
        }
    }
}

struct StudioPill: View {
    let title: String
    var tone: Color = TypefluxColor.secondaryLabel.color
    var fill: Color = TypefluxColor.controlBackground.color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(.caption, weight: .semibold))
            }
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, TypefluxSpacing.regular.value(for: .classic))
        .padding(.vertical, 7)
        .background(Capsule().fill(fill))
    }
}

/// A small inline tag badge, distinct from `StudioPill`.
/// Use this for short contextual labels (e.g. "限时免费", "Beta").
/// Reuse this component anywhere a compact tag callout is needed.
struct StudioTag: View {
    let title: String
    var tone: Color = TypefluxColor.accent.color
    var fill: Color = TypefluxColor.accent.color.opacity(0.12)
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(.caption2, weight: .bold))
            }
            Text(title)
                .font(.system(.footnote, weight: .semibold))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill))
    }
}

struct StudioMetricCard: View {
    let icon: String
    let value: String
    let caption: String
    let badge: String?

    var body: some View {
        StudioCard {
            HStack(alignment: .center) {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                    .fill(TypefluxColor.accent.color.opacity(0.12))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(TypefluxColor.accent.color)
                    )

                Spacer()

                if let badge {
                    StudioPill(title: badge)
                }
            }

            Text(value)
                .font(.system(.largeTitle, weight: .semibold))
                .foregroundStyle(TypefluxColor.label.color)

            Text(caption)
                .font(.system(.body))
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
        }
        .frame(maxWidth: .infinity, minHeight: StudioWindowMetrics.compactMetricMinHeight, alignment: .leading)
    }
}

struct StudioSettingRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let badge: String?
    let accessory: Accessory

    init(title: String, subtitle: String, badge: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.accessory = accessory()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                labels.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                accessory.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                labels
                accessory
            }
        }
        .padding(.vertical, TypefluxSpacing.small.value(for: .classic))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(TypefluxColor.label.color)
                if let badge { StudioPill(title: badge) }
            }
            Text(subtitle)
                .font(.system(.body))
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StudioTextInputCard<LabelTrailing: View>: View {
    let label: String
    let placeholder: String
    var horizontal = false
    @Binding var text: String
    var secure: Bool = false
    @ViewBuilder var labelTrailing: () -> LabelTrailing

    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool = false,
        horizontal: Bool = false,
        @ViewBuilder labelTrailing: @escaping () -> LabelTrailing = { EmptyView() }
    ) {
        self.label = label
        self.placeholder = placeholder
        self.horizontal = horizontal
        _text = text
        self.secure = secure
        self.labelTrailing = labelTrailing
    }

    var body: some View {
        StudioInputLayout(label: label, horizontal: horizontal, labelTrailing: labelTrailing) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(TypefluxColor.label.color)
            .labelsHidden().accessibilityLabel(label)
        }
    }
}

struct StudioSuggestedTextInputCard<LabelTrailing: View>: View {
    let label: String
    let placeholder: String
    var horizontal = false
    let suggestions: [String]
    @Binding var text: String
    @ViewBuilder var labelTrailing: () -> LabelTrailing

    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        suggestions: [String],
        horizontal: Bool = false,
        @ViewBuilder labelTrailing: @escaping () -> LabelTrailing = { EmptyView() }
    ) {
        self.label = label
        self.placeholder = placeholder
        self.horizontal = horizontal
        _text = text
        self.suggestions = suggestions
        self.labelTrailing = labelTrailing
    }

    private var normalizedSuggestions: [String] {
        var seen = Set<String>()
        return suggestions.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    var body: some View {
        StudioInputLayout(label: label, horizontal: horizontal, labelTrailing: labelTrailing) {
            HStack(spacing: 4) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(TypefluxColor.label.color)
                    .labelsHidden().accessibilityLabel(label)

                if !normalizedSuggestions.isEmpty {
                    HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
                        ZStack {
                            Menu {
                                ForEach(normalizedSuggestions, id: \.self) { suggestion in
                                    Button(suggestion) {
                                        text = suggestion
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                                    .frame(width: 24, height: SettingsControlMetrics.height)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .accessibilityLabel(L("common.selectSuggestedValue"))
                        }
                        .frame(width: 24, height: SettingsControlMetrics.height)
                        .studioTooltip(L("common.selectSuggestedValue"), yOffset: 28)
                    }
                    .padding(.trailing, 3)
                }
            }
            .frame(height: SettingsControlMetrics.height)
        }
    }
}

/// Keep legacy stacked forms unchanged while provider connections share a horizontal row.
private struct StudioInputLayout<Field: View, LabelTrailing: View>: View {
    let label: String
    let horizontal: Bool
    @ViewBuilder var labelTrailing: () -> LabelTrailing
    @ViewBuilder var field: () -> Field

    var body: some View {
        if horizontal {
            VStack(spacing: 0) {
                ModelFormRow(title: label) {
                    HStack(spacing: 8) {
                        field()
                        labelTrailing()
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    Spacer()
                    labelTrailing()
                }
                field()
            }
        }
    }
}

struct StudioMenuPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var width: CGFloat?
    var height: CGFloat?

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        TypefluxPopup(title: selectedLabel, options: options, selection: $selection)
            .frame(width: width, height: height ?? SettingsControlMetrics.menuHeight)
            .fixedSize()
    }
}
