import AppKit
import SwiftUI

struct StudioInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? StudioTheme.Opacity.pressedFade : 1)
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
                .font(.studioBody(StudioTheme.Typography.tooltip, weight: .semibold))
                .foregroundStyle(StudioTheme.Colors.white)
                .lineLimit(1)
                .padding(.horizontal, StudioTheme.Insets.tooltipHorizontal)
                .padding(.vertical, StudioTheme.Insets.tooltipVertical)
                .background(
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.tooltip, style: .continuous)
                        .fill(StudioTheme.tooltipBackground)
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

final class StudioRoundedVisualEffectView: NSVisualEffectView {
    var preferredCornerRadius: CGFloat?

    override func layout() {
        super.layout()
        layer?.cornerRadius = preferredCornerRadius ?? 0
    }
}

struct StudioVisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat?

    func makeNSView(context _: Context) -> StudioRoundedVisualEffectView {
        let view = StudioRoundedVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredCornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: StudioRoundedVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
        nsView.preferredCornerRadius = cornerRadius
        nsView.needsLayout = true
    }
}

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
        tintOpacity: Double = StudioTheme.Opacity.glassSurfaceTint,
        scrimOpacity: Double = StudioTheme.Opacity.glassSurfaceScrim,
        strokeOpacity: Double = StudioTheme.Opacity.glassHighlight,
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
                shape.fill(StudioTheme.controlSurface)
            } else {
                #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        shape
                            .fill(Color.clear)
                            .glassEffect(
                                Glass.regular
                                    .interactive(interactive)
                                    .tint(StudioTheme.glassTint.opacity(intensity.nativeFrostOpacity(tintOpacity))),
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
                            StudioTheme.glassStrokeHighlight.opacity(strokeOpacity),
                            StudioTheme.glassStrokeHighlight.opacity(strokeOpacity * 0.28),
                            StudioTheme.glassStrokeShadow.opacity(0.50)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: StudioTheme.BorderWidth.thin
                )
                .opacity(usesMaterial && !usesNativeGlass ? 1 : 0)
        )
        .overlay(
            shape
                .inset(by: StudioTheme.BorderWidth.thin + 0.5)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            StudioTheme.glassInnerHighlight,
                            Color.clear,
                            StudioTheme.glassInnerHighlight.opacity(0.42)
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
                .fill(StudioTheme.glassScrim.opacity(intensity.legacyFrostOpacity(scrimOpacity)))
            shape
                .fill(StudioTheme.glassTint.opacity(intensity.legacyFrostOpacity(tintOpacity)))
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
        return hovering ? StudioTheme.accentHover : StudioTheme.accent
    }

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .frame(minWidth: minWidth)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(overlay)
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
            .scaleEffect(isPressed ? 0.985 : 1)
            .opacity(opacity)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: isLoading)
    }

    @ViewBuilder
    private var background: some View {
        let buttonShape = RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)

        switch variant {
        case .primary where Self.solidPrimaryFill(dark: colorScheme == .dark, hovering: isHovering || isPressed) != nil:
            buttonShape
                .fill(Self.solidPrimaryFill(dark: colorScheme == .dark, hovering: isHovering || isPressed) ?? StudioTheme.accent)
                .shadow(color: StudioTheme.accent.opacity(0.18), radius: 8, x: 0, y: 5)
        case .primary:
            buttonShape
                .fill(
                    LinearGradient(
                        colors: [
                            StudioTheme.accent.opacity(0.92),
                            StudioTheme.accent
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .brightness(isPressed ? -0.06 : (isLoading ? -0.03 : 0))
                .shadow(color: StudioTheme.accent.opacity(0.18), radius: 8, x: 0, y: 5)
        case .secondary:
            ZStack {
                StudioLiquidGlassBackground(
                    shape: buttonShape,
                    cornerRadius: StudioTheme.CornerRadius.xLarge,
                    tintOpacity: isPressed ? 0.72 : StudioTheme.Opacity.glassControlTint,
                    scrimOpacity: isPressed ? 0.76 : StudioTheme.Opacity.glassControlScrim,
                    interactive: true
                )

                buttonShape
                    .fill(isPressed ? StudioTheme.selectionSurface : StudioTheme.controlSurface)
                    .opacity(style.usesGlass && !reduceTransparency && contrast != .increased
                        ? (isPressed ? 0.22 : 0.08) : 1)
            }
            .brightness(isPressed ? -0.03 : (isLoading ? -0.015 : 0))
        case .ghost:
            buttonShape
                .fill(isPressed ? StudioTheme
                    .controlSurface : (isLoading ? StudioTheme.controlSurface.opacity(0.62) : Color.clear))
        }
    }

    private var overlay: some View {
        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
            .stroke(borderColor, lineWidth: borderWidth)
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            .white
        case .secondary:
            StudioTheme.textPrimary
        case .ghost:
            StudioTheme.textSecondary
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            Color.clear
        case .secondary, .ghost:
            StudioTheme.border.opacity(isPressed || isLoading ? 0.82 : 1)
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .ghost:
            isPressed || isLoading ? StudioTheme.BorderWidth.thin : 0
        case .primary, .secondary:
            StudioTheme.BorderWidth.thin
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

/// Window navigation yields space before settings panes become cramped.
struct StudioShellLayout {
    let width: CGFloat
    var sidebarInline: Bool { width >= 1040 }
    var sidebarWidth: CGFloat { sidebarInline ? StudioTheme.sidebarWidth : 0 }
    var horizontalInset: CGFloat { width < 860 ? 12 : StudioTheme.contentInset }
    var contentWidth: CGFloat {
        min(StudioTheme.contentMaxWidth, max(0, width - sidebarWidth - horizontalInset * 2))
    }
}

struct StudioShell<Content: View>: View {
    @State private var showsSidebar = false

    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void
    let onAccountAction: () -> Void
    let searchText: Binding<String>
    let searchPlaceholder: String
    let accountDefaults: UserDefaults
    let content: (CGSize) -> Content

    init(
        currentSection: StudioSection,
        onSelect: @escaping (StudioSection) -> Void,
        onAccountAction: @escaping () -> Void,
        searchText: Binding<String>,
        searchPlaceholder: String,
        accountDefaults: UserDefaults,
        @ViewBuilder content: @escaping (CGSize) -> Content
    ) {
        self.currentSection = currentSection
        self.onSelect = onSelect
        self.onAccountAction = onAccountAction
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.accountDefaults = accountDefaults
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = StudioShellLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.sidebarInline {
                    sidebar(compact: geometry.size.height < 500)
                        .askSidePanel(edge: .leading)
                        .frame(width: layout.sidebarWidth, height: geometry.size.height)
                }
                VStack(spacing: 0) {
                    if !layout.sidebarInline { compactNavigation(height: geometry.size.height) }
                    GeometryReader { proxy in
                        Group {
                            if currentSection == .models {
                                pageContent(size: proxy.size, inset: layout.horizontalInset)
                            } else {
                                ScrollView { pageContent(size: proxy.size, inset: layout.horizontalInset) }
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: max(0, geometry.size.width - layout.sidebarWidth), height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .environment(\.studioWindowWidth, geometry.size.width)
            .onChange(of: layout.sidebarInline) { inline in if inline { showsSidebar = false } }
        }
        .background(AskWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: currentSection) { _ in showsSidebar = false }
    }

    private func sidebar(compact: Bool) -> some View {
        StudioSidebar(currentSection: currentSection, onSelect: onSelect,
                      onAccountAction: onAccountAction, defaults: accountDefaults, compact: compact)
    }

    private func compactNavigation(height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: AskResultWindowView.trafficLightClearance)
            AskIconGhostButton(label: L("ask.sidebar.toggle"), systemImage: "sidebar.left") {
                showsSidebar.toggle()
            }
            .accessibilityIdentifier("studio.sidebarToggle")
            .popover(isPresented: $showsSidebar) {
                sidebar(compact: height < 600).frame(width: StudioTheme.sidebarWidth, height: min(600, max(240, height - 60)))
                    .background(AskWindowBackdrop())
            }
            .askCollapsedSidebarTools()
            Text(currentSection.shellTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 12)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private func pageContent(size: CGSize, inset: CGFloat) -> some View {
        let contentWidth = min(StudioTheme.contentMaxWidth, max(size.width - inset * 2, 0))
        return VStack(alignment: .leading, spacing: StudioTheme.Spacing.section) {
            content(CGSize(width: contentWidth, height: size.height))
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .padding(.horizontal, inset)
        .padding(.top, StudioTheme.Layout.shellContentTopInset)
        .padding(.bottom, currentSection == .models ? 0 : StudioTheme.Layout.shellContentBottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            StudioTheme.windowBackground
                .background(AskWindowBackdrop.base(dark: colorScheme == .dark))
        } else if colorScheme == .dark {
            ZStack {
                StudioVisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow, cornerRadius: nil)

                StudioTheme.windowBackground
                    .opacity(intensity.nativeFrostOpacity(tintOpacity))
                AskWindowBackdrop.base(dark: true).opacity(intensity.extraTintOpacity)
            }
        } else {
            ZStack {
                StudioVisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow, cornerRadius: nil)

                StudioTheme.windowBackground
                    .opacity(intensity.nativeFrostOpacity(tintOpacity))

                LinearGradient(
                    colors: [
                        StudioTheme.windowHighlight.opacity(0.92),
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

struct StudioSidebar: View {
    @Environment(\.interfaceStyle) private var style
    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void
    let onAccountAction: () -> Void
    let defaults: UserDefaults
    let compact: Bool
    @ObservedObject private var auth = AuthState.shared
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TypefluxLogoBadge(size: 26, symbolSize: 14, backgroundShape: .circle, showsBorder: false)
                Text(L("sidebar.appName"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(appVersionBadge)
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, AskMetrics.titleBarRowHeight)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(StudioSection.sidebarUpperCases, id: \.self) { section in
                        sidebarNavigationButton(for: section)
                    }
                }
                .padding(.horizontal, 10)
            }

            SidebarAccountFooter(auth: auth, compact: compact, defaults: defaults,
                                 onSignIn: onAccountAction, onOpenAccount: onAccountAction)
        }
        .environment(\.locale, localization.locale)
    }

    private var appVersionBadge: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

}

extension StudioSidebar {
    private func sidebarNavigationButton(for section: StudioSection) -> some View {
        let isSelected = section == currentSection.sidebarSection
        return Button(action: { onSelect(section) }) {
            HStack(spacing: StudioTheme.Spacing.medium) {
                Image(systemName: section.sidebarIconName)
                    .font(.system(size: StudioTheme.Typography.iconRegular, weight: .medium))
                    .frame(width: StudioTheme.ControlSize.sidebarNavigationIcon)

                Text(section.sidebarTitle)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .medium))

                Spacer()
            }
            .foregroundStyle(Self.navigationColor(selected: isSelected, glass: style.usesGlass))
            .padding(.horizontal, StudioTheme.Insets.sidebarItemHorizontal)
            .padding(.vertical, StudioTheme.Insets.sidebarItemVertical)
            .modifier(StudioSidebarRowBackground(selected: isSelected,
                                                 corner: style.ask.sidebarRowCorner))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    /// Glass marks the open page like the conversation sidebar, in the accent;
    /// classic keeps its accent text.
    static func navigationColor(selected: Bool, glass: Bool) -> Color {
        guard selected else { return StudioTheme.textSecondary }
        return glass ? AskTheme.accent : StudioTheme.accentText
    }
}

/// The sidebar row's background. In light the selected row is a raised white
/// block (hairline + 1pt shadow) on the grey sidebar; in dark it takes the
/// library shelves' sidebar selection.
struct StudioSidebarRowBackground: ViewModifier {
    var selected: Bool
    var corner: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func usesRaisedBlock(selected: Bool, dark: Bool) -> Bool { selected && !dark }

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.usesRaisedBlock(selected: selected, dark: colorScheme == .dark) {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            content
                .background(shape.fill(StudioTheme.sidebarSelection)
                    .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1))
                .overlay(shape.strokeBorder(StudioTheme.sidebarSelectionStroke, lineWidth: 1))
        } else {
            content.askNotesRow(selected: selected, hovering: false, corner: corner, sidebar: true)
        }
    }
}

struct StudioHeroHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                Text(title)
                    .font(.studioDisplay(StudioTheme.Typography.heroTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                if let badge {
                    StudioPill(title: badge)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: StudioTheme.Layout.heroMaxWidth, alignment: .leading)
            }
        }
    }
}

struct StudioSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
            .foregroundStyle(StudioTheme.textSecondary)
    }
}

struct StudioCard<Content: View>: View {
    enum Texture {
        case standard
        case softWaves
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style

    var padding: CGFloat = StudioTheme.Insets.cardDefault
    var showsShadow: Bool = false
    var isHighlighted: Bool = false
    var isDimmed: Bool = false
    var texture: Texture = .standard
    /// Suppress the surface and outline without changing content spacing.
    var showsChrome: Bool = true
    let content: Content

    init(
        padding: CGFloat = StudioTheme.Insets.cardDefault,
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
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardCompact) {
            content
        }
        .padding(padding)
        .background(
            ZStack {
                if showsChrome {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                        .fill(style.usesGlass ? StudioTheme.cardFill : AskClassic.card)
                    cardTextureOverlay

                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                        .fill(selectionOverlay)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(
                    showsChrome ? cardBorderColor : .clear,
                    lineWidth: isHighlighted ? StudioTheme.BorderWidth.emphasis : (usesLightGlassCard ? 1 : 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
        .shadow(
            color: StudioTheme.shadow
                .opacity(!showsChrome || !style
                    .usesGlass || usesLightGlassCard || !showsShadow ? 0 : (isHighlighted ? 0.20 : 0.16)),
            radius: isHighlighted ? StudioTheme.Shadow.cardRadius + 2 : StudioTheme.Shadow.cardRadius,
            x: 0,
            y: isHighlighted ? StudioTheme.Shadow.cardY + 1 : StudioTheme.Shadow.cardY
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
            return StudioTheme.accentSoft.opacity(0.36)
        }

        if isDimmed {
            return StudioTheme.surfaceMuted.opacity(0.38)
        }

        return Color.clear
    }

    private var cardBorderColor: Color {
        if isHighlighted {
            return StudioTheme.accent.opacity(0.34)
        }

        return usesLightGlassCard ? StudioTheme.cardStroke : AskTheme.separator
    }

    private var cardTextureOverlay: some View {
        Group {
            if texture == .softWaves {
                softWaveTexture
            } else if colorScheme == .dark {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.clear,
                                StudioTheme.accentSoft.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        StudioTheme.border.opacity(0.08)
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
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
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
                                        StudioTheme.accent.opacity(accentOpacity),
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
                                        StudioTheme.accentSoft.opacity(accentOpacity * 0.52),
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

                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        isHighlighted ? StudioTheme.accentSoft.opacity(accentOpacity * 0.58) : Color
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
            minWidth: variant == .ghost ? nil : StudioTheme.ControlSize.buttonMinWidth,
            action: action
        ) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? .white : StudioTheme.textSecondary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                }
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            }
            .padding(.horizontal, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonVertical)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
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
                        .tint(variant == .primary ? .white : StudioTheme.textSecondary)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: StudioTheme.Typography.iconRegular, weight: .medium))
                }
            }
            .frame(width: frame, height: frame)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
        }
    }
}

struct StudioPill: View {
    let title: String
    var tone: Color = StudioTheme.textSecondary
    var fill: Color = StudioTheme.surfaceMuted
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: StudioTheme.Typography.caption - 1, weight: .semibold))
            }
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, StudioTheme.Insets.pillHorizontal)
        .padding(.vertical, StudioTheme.Insets.pillVertical)
        .background(Capsule().fill(fill))
    }
}

/// A small inline tag badge, distinct from `StudioPill`.
/// Use this for short contextual labels (e.g. "限时免费", "Beta").
/// Reuse this component anywhere a compact tag callout is needed.
struct StudioTag: View {
    let title: String
    var tone: Color = StudioTheme.accent
    var fill: Color = StudioTheme.accent.opacity(0.12)
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: StudioTheme.Typography.caption - 2, weight: .bold))
            }
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption - 1, weight: .semibold))
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
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .fill(StudioTheme.iconTileSurface)
                    .frame(width: StudioTheme.ControlSize.overviewBadge, height: StudioTheme.ControlSize.overviewBadge)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: StudioTheme.Typography.iconRegular, weight: .semibold))
                            .foregroundStyle(StudioTheme.accent)
                    )

                Spacer()

                if let badge {
                    StudioPill(title: badge)
                }
            }

            Text(value)
                .font(.studioDisplay(StudioTheme.Typography.heroMetric, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(caption)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.compactMetricMinHeight, alignment: .leading)
    }
}

struct StudioSettingRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let badge: String?
    let accessory: Accessory
    @State private var isHovering = false

    init(title: String, subtitle: String, badge: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.accessory = accessory()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
                labels.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                accessory.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                labels
                accessory
            }
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
        .onHover { isHovering = $0 }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .accessibilityHint(subtitle)
                if !subtitle.isEmpty {
                    SettingsDescriptionHint(detail: subtitle, visible: isHovering)
                }
                if let badge { StudioPill(title: badge) }
            }
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
            if secure {
                TFSecureField(placeholder: placeholder, text: $text).accessibilityLabel(label)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(TFTextFieldStyle())
                    .accessibilityLabel(label)
            }
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

    var body: some View {
        StudioInputLayout(label: label, horizontal: horizontal, labelTrailing: labelTrailing) {
            TFComboField(placeholder: placeholder, text: $text, suggestions: suggestions, accessibilityLabel: label)
        }
    }
}

/// Provider connections put the label in a column beside the field; stacked forms (onboarding)
/// put a caption above it.
private struct StudioInputLayout<Field: View, LabelTrailing: View>: View {
    let label: String
    let horizontal: Bool
    @ViewBuilder var labelTrailing: () -> LabelTrailing
    @ViewBuilder var field: () -> Field

    var body: some View {
        if horizontal {
            VStack(spacing: 0) {
                ModelFormRow(title: label) {
                    HStack(spacing: TFMetrics.toolbarSpacing) {
                        field()
                        labelTrailing()
                    }
                }
                TFDivider.form
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
                    Spacer()
                    labelTrailing()
                }
                field()
            }
        }
    }
}

struct StudioHistoryRow: View {
    let record: HistoryPresentationRecord
    let onCopyResult: (() -> Void)?
    let onCopyTranscript: (() -> Void)?
    let onDownloadAudio: (() -> Void)?
    let onPlayAudio: (() -> Void)?
    let isAudioPlaying: Bool
    let onDelete: (() -> Void)?
    let onRetry: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    timestamp.frame(width: 48, alignment: .leading)
                    preview.frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                    rowActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        timestamp
                        Spacer(minLength: 0)
                        rowActions
                    }
                    preview
                }
            }

            if isExpanded {
                details
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            historyActionsMenuContent
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = record.audioFilePath, !path.isEmpty {
                TFDetailBlock(title: L("history.detail.audioPath"), content: path) {
                    if let onPlayAudio {
                        TFButton(title: L(isAudioPlaying ? "history.action.stopAudio" : "history.action.playAudio"),
                                 systemImage: isAudioPlaying ? "stop.circle" : "play.circle", kind: .plain,
                                 iconOnly: true, action: onPlayAudio)
                    }
                }
            } else {
                TFDetailBlock(title: L("history.detail.audioPath"), content: L("history.detail.noAudioFile"))
            }
            detail(L("history.detail.rawTranscript"), record.transcriptText,
                   copyAction: (record.transcriptText?.isEmpty ?? true) ? nil : onCopyTranscript)
            detail(L("history.detail.personaResult"), record.personaResultText)
            if let openCCResult = record.openCCResultText {
                detail(openCCTitle, openCCResult)
            }
            if let postProcessedText = record.postProcessedText, showsPostProcessed(postProcessedText) {
                detail(L("history.detail.postProcessedResult"), postProcessedText)
            }
            detail(L("history.detail.selectionOriginal"), record.selectionOriginalText)
            detail(L("history.detail.selectionEdited"), record.selectionEditedText)
            if let timeline = record.pipelineTimeline {
                HistoryPipelineTimelineView(title: L("history.detail.pipelineStats"), timeline: timeline)
            }
            detail(L("history.detail.error"), record.errorMessage, emphasize: true)
        }
        .padding(.top, 2)
    }

    private var openCCTitle: String {
        let configName = switch record.openCCConfig {
        case "s2twp": L("settings.output.opencc.config.s2twp")
        case "s2tw": L("settings.output.opencc.config.s2tw")
        case "s2hk": L("settings.output.opencc.config.s2hk")
        case "t2s": L("settings.output.opencc.config.t2s")
        default: ""
        }
        return configName.isEmpty ? L("history.detail.openCCResult") : "\(L("history.detail.openCCResult")) (\(configName))"
    }

    /// The final text is shown when a step changed the transcript, or when it differs from the last step.
    private func showsPostProcessed(_ text: String) -> Bool {
        let anyProcessingHappened = record.personaResultText != nil || record.openCCResultText != nil
            || record.selectionEditedText != nil
        let source = record.openCCResultText ?? record.personaResultText ?? record.transcriptText
        return anyProcessingHappened || text != source
    }

    @ViewBuilder
    private func detail(_ title: String, _ content: String?, emphasize: Bool = false,
                        copyAction: (() -> Void)? = nil) -> some View {
        if let content, !content.isEmpty {
            TFDetailBlock(title: title, content: content, emphasize: emphasize) {
                if let copyAction {
                    TFButton(title: L("history.action.copyTranscript"), systemImage: "doc.on.doc", kind: .plain,
                             iconOnly: true, action: copyAction)
                }
            }
        }
    }

    private var timestamp: some View {
        Text(record.timestampText)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(TFColors.textTertiary)
            .fixedSize()
            .padding(.top, 6)
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(record.previewText)
                .font(.system(size: 13))
                .foregroundStyle(TFColors.textPrimary)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if record.hasFailure {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TFColors.danger)
                    .padding(.top, 2)
                    .help(record.failureMessage ?? L("workflow.processing.failed"))
                    .accessibilityLabel(record.failureMessage ?? L("workflow.processing.failed"))
            }
        }
        .padding(.top, 5)
    }

    private var rowActions: some View {
        HStack(spacing: 2) {
            TFMenuButton(title: L("history.action.more"), systemImage: "ellipsis", kind: .plain, iconOnly: true,
                         actions: menuActions)
            TFButton(title: isExpanded ? L("common.collapse") : L("common.expand"),
                     systemImage: isExpanded ? "chevron.up" : "chevron.down", kind: .plain, iconOnly: true) {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }
            .accessibilityIdentifier("history.expand.\(record.id)")
        }
        .tfControlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The row's actions, shared by the "⋯" button and the context menu.
    private var menuActions: [TFMenuAction] {
        var actions: [TFMenuAction] = []
        let canCopyResult = onCopyResult != nil && record.hasTranscriptToCopy
        let canCopyTranscript = onCopyTranscript != nil && !(record.transcriptText?.isEmpty ?? true)
        if canCopyResult, let onCopyResult {
            actions.append(.action(L("history.action.copyResult"), systemImage: "doc.on.doc", onCopyResult))
        }
        if canCopyTranscript, let onCopyTranscript {
            actions.append(.action(L("history.action.copyTranscript"), systemImage: "doc.on.doc", onCopyTranscript))
        }
        if canCopyResult || canCopyTranscript { actions.append(.separator) }
        if let onRetry {
            actions.append(.action(L("common.retry"), systemImage: "arrow.clockwise", isEnabled: record.canRetry,
                                   onRetry))
        }
        if let onDownloadAudio {
            actions.append(.action(L("history.action.downloadAudio"), systemImage: "arrow.down.circle",
                                   isEnabled: record.audioFilePath != nil, onDownloadAudio))
        }
        if let onDelete {
            actions.append(.separator)
            actions.append(.action(L("history.action.deleteTranscript"), systemImage: "trash", destructive: true,
                                   onDelete))
        }
        return actions
    }

    @ViewBuilder
    private var historyActionsMenuContent: some View {
        if let onCopyResult, record.hasTranscriptToCopy {
            Button(L("history.action.copyResult"), systemImage: "doc.on.doc", action: onCopyResult)
        }
        if let onCopyTranscript, !(record.transcriptText?.isEmpty ?? true) {
            Button(L("history.action.copyTranscript"), systemImage: "doc.on.doc", action: onCopyTranscript)
        }
        if (onCopyResult != nil && record.hasTranscriptToCopy) || !(record.transcriptText?.isEmpty ?? true) {
            Divider()
        }
        if let onRetry {
            Button(L("common.retry"), systemImage: "arrow.clockwise", action: onRetry)
                .disabled(!record.canRetry)
        }
        if let onDownloadAudio {
            Button(L("history.action.downloadAudio"), systemImage: "arrow.down.circle", action: onDownloadAudio)
                .disabled(record.audioFilePath == nil)
        }
        Divider()
        if let onDelete {
            Button(L("history.action.deleteTranscript"), systemImage: "trash", role: .destructive, action: onDelete)
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
        SettingsMenuPicker(title: selectedLabel, options: options, selection: $selection)
            .frame(width: width, height: height ?? SettingsControlMetrics.menuHeight)
            .fixedSize()
    }
}
