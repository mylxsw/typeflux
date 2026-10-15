import SwiftUI

/// Button styles (spec §3). A region has at most one `.primary` button, placed last.
enum TFButtonKind: String, CaseIterable, Identifiable {
    /// Accent fill: the most important action in a region.
    case primary
    /// Control fill with a hairline: every other action. The default.
    case secondary
    /// No fill until hover: small actions in rows and cards; icon-only buttons.
    case plain
    /// Accent text: a light entry point inside a sentence or an empty state.
    case link
    /// Glass: only on layers that float over content.
    case glass

    var id: String { rawValue }
}

/// What a button looks like in one interaction state. Kept free of SwiftUI so it can be tested.
struct TFButtonAppearance: Equatable {
    enum Fill: Equatable { case none, control, accent, accentHover, danger, glass }
    enum Foreground: Equatable { case onFill, primary, secondary, accent, danger }
    enum Overlay: Equatable { case none, hover, pressed, darken }

    var fill: Fill
    var foreground: Foreground
    var overlay: Overlay
    var hasBorder: Bool
    var opacity: Double = 1

    /// `destructive` turns the text red; only a destructive `.primary` button is filled red,
    /// and that belongs in a confirmation dialog.
    static func resolve(kind: TFButtonKind, destructive: Bool, isHovering: Bool, isPressed: Bool) -> Self {
        let interaction: Overlay = isPressed ? .pressed : (isHovering ? .hover : .none)
        switch kind {
        case .primary:
            if destructive {
                let overlay: Overlay = isPressed ? .darken : (isHovering ? .hover : .none)
                return .init(fill: .danger, foreground: .onFill, overlay: overlay, hasBorder: false)
            }
            return .init(fill: isHovering && !isPressed ? .accentHover : .accent, foreground: .onFill,
                         overlay: isPressed ? .darken : .none, hasBorder: false)
        case .secondary:
            return .init(fill: .control, foreground: destructive ? .danger : .primary, overlay: interaction,
                         hasBorder: true)
        case .plain:
            let foreground: Foreground = destructive ? .danger : (isHovering || isPressed ? .primary : .secondary)
            return .init(fill: .none, foreground: foreground, overlay: interaction, hasBorder: false)
        case .link:
            return .init(fill: .none, foreground: destructive ? .danger : .accent, overlay: .none, hasBorder: false,
                         opacity: isHovering || isPressed ? 0.78 : 1)
        case .glass:
            return .init(fill: .glass, foreground: destructive ? .danger : .primary, overlay: interaction,
                         hasBorder: false)
        }
    }

    var foregroundColor: Color {
        switch foreground {
        case .onFill: .white
        case .primary: TFColors.textPrimary
        case .secondary: TFColors.textSecondary
        case .accent: TFColors.accent
        case .danger: TFColors.danger
        }
    }

    var overlayColor: Color {
        switch overlay {
        case .none: .clear
        case .hover: TFColors.hoverOverlay
        case .pressed: TFColors.pressedOverlay
        case .darken: Color.black.opacity(0.12)
        }
    }
}

/// The capsule chrome shared by every button-like component (buttons, pop-up and menu triggers).
struct TFButtonStyle: ButtonStyle {
    var kind: TFButtonKind = .secondary
    var destructive = false
    /// Nil follows the environment's `tfControlSize`.
    var size: TFControlSize?
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        TFButtonChrome(kind: kind, destructive: destructive, size: size, iconOnly: iconOnly,
                       isPressed: configuration.isPressed, hoverOverride: nil) {
            configuration.label
        }
    }
}

/// Draws the capsule, fill, hover/press overlays and press scale around a label.
struct TFButtonChrome<Label: View>: View {
    var kind: TFButtonKind
    var destructive: Bool
    var size: TFControlSize?
    var iconOnly: Bool
    var isPressed: Bool
    /// Set when an overlay (such as a native menu button) receives the pointer instead of the chrome.
    var hoverOverride: Bool?
    @ViewBuilder var label: Label
    @Environment(\.tfControlSize) private var environmentSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var resolvedSize: TFControlSize { size ?? environmentSize }

    var body: some View {
        let size = resolvedSize
        let appearance = TFButtonAppearance.resolve(kind: kind, destructive: destructive,
                                                    isHovering: (hoverOverride ?? isHovering) && isEnabled,
                                                    isPressed: isPressed)
        label
            .font(.system(size: size.fontSize, weight: kind == .primary ? .semibold : size.fontWeight))
            .foregroundStyle(appearance.foregroundColor)
            .lineLimit(1)
            .padding(.horizontal, iconOnly ? 0 : (kind == .link ? 4 : size.horizontalPadding))
            .frame(width: iconOnly ? size.height : nil, height: size.height)
            .frame(minWidth: iconOnly || kind == .link ? nil : size.minimumTextButtonWidth)
            .background { fill(appearance.fill, size: size) }
            .overlay { Capsule().fill(appearance.overlayColor).allowsHitTesting(false) }
            .overlay {
                if appearance.hasBorder {
                    Capsule().strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth).allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .tfCapsuleFocusEffect()
            .scaleEffect(isPressed && !reduceMotion ? TFMetrics.pressedScale : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
            .opacity(isEnabled ? appearance.opacity : TFMetrics.disabledOpacity)
            .onHover { isHovering = $0 }
    }

    @ViewBuilder private func fill(_ fill: TFButtonAppearance.Fill, size: TFControlSize) -> some View {
        switch fill {
        case .none: Color.clear
        case .control: Capsule().fill(TFColors.control)
        case .accent: Capsule().fill(TFColors.accent)
        case .accentHover: Capsule().fill(TFColors.accentHover)
        case .danger: Capsule().fill(TFColors.danger)
        case .glass:
            Color.clear.modifier(AskInWindowGlass(corner: size.height / 2, opaqueFill: AskTheme.glassFill,
                                                  cornerStyle: .circular, elevation: .control))
        }
    }
}

extension View {
    /// The system keyboard focus ring follows the capsule instead of the bounding box.
    @ViewBuilder func tfCapsuleFocusEffect() -> some View {
        if #available(macOS 14.0, *) {
            contentShape(.focusEffect, Capsule())
        } else {
            self
        }
    }
}

/// A text button, optionally with a leading SF Symbol, a trailing menu chevron or a loading spinner.
struct TFButton: View {
    let title: String
    var systemImage: String?
    var kind: TFButtonKind = .secondary
    var destructive = false
    var size: TFControlSize?
    /// Shows only the symbol in a circle; the title becomes the tooltip and accessibility label.
    var iconOnly = false
    /// Replaces the icon with a spinner, keeps the width and ignores clicks.
    var isLoading = false
    var showsMenuIndicator = false
    let action: () -> Void
    @Environment(\.tfControlSize) private var environmentSize

    var body: some View {
        let size = size ?? environmentSize
        Button(action: action) {
            HStack(spacing: size.spacing) {
                leading(size: size)
                if !iconOnly {
                    Text(title)
                        .opacity(isLoading && systemImage == nil ? 0 : 1)
                        .overlay {
                            if isLoading && systemImage == nil { TFSpinner(size: size) }
                        }
                }
                if showsMenuIndicator && !iconOnly {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.75)
                }
            }
        }
        .buttonStyle(TFButtonStyle(kind: kind, destructive: destructive, size: size, iconOnly: iconOnly))
        .allowsHitTesting(!isLoading)
        .help(iconOnly ? title : "")
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? L("component.loading") : "")
    }

    @ViewBuilder private func leading(size: TFControlSize) -> some View {
        if isLoading && (systemImage != nil || iconOnly) {
            TFSpinner(size: size)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size.iconSize, weight: .semibold))
        }
    }
}

/// A small indeterminate spinner sized to the control's icon.
struct TFSpinner: View {
    var size: TFControlSize = .regular

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(size.iconSize / 16)
            .frame(width: size.iconSize, height: size.iconSize)
            .accessibilityHidden(true)
    }
}
