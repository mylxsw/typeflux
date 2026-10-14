import SwiftUI

/// Geometry that differs between Liquid Glass and classic, like `AskStyleMetrics`.
struct HelpMetrics: Equatable {
    var panelCorner: CGFloat
    var blockCorner: CGFloat
    var rowCorner: CGFloat
    var navRowHeight: CGFloat
    var keycapCorner: CGFloat

    static let liquidGlass = HelpMetrics(panelCorner: 26, blockCorner: 14, rowCorner: 10, navRowHeight: 36,
                                         keycapCorner: 5)
    static let classic = HelpMetrics(panelCorner: 12, blockCorner: 10, rowCorner: 6, navRowHeight: 30,
                                     keycapCorner: 4)
}

extension InterfaceStyle {
    var help: HelpMetrics { usesGlass ? .liquidGlass : .classic }
}

/// The guide's colors: the launcher's and the classic style's existing tokens.
enum HelpTheme {
    static let block = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.66),
        dark: NSColor(calibratedWhite: 1, alpha: 0.045)
    )
    static let blockEdge = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )
    /// A selected row on glass: the notes list's blue wash with a hairline.
    static let glassSelection = StudioTheme.dynamic(
        light: NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 0.13),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1, alpha: 0.20)
    )
    static let glassSelectionEdge = StudioTheme.dynamic(
        light: NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 0.28),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1, alpha: 0.42)
    )

    static func blockFill(_ style: InterfaceStyle) -> Color { style.usesGlass ? block : AskClassic.card }
    static func blockBorder(_ style: InterfaceStyle) -> Color { style.usesGlass ? blockEdge : AskClassic.cardBorder }
    static func selection(_ style: InterfaceStyle) -> Color { style.usesGlass ? glassSelection : AskClassic.selection }
    static func selectionEdge(_ style: InterfaceStyle) -> Color { style.usesGlass ? glassSelectionEdge : .clear }
    /// The recessed area behind the start page's illustrations.
    static func well(_ style: InterfaceStyle) -> Color { style.usesGlass ? AskTheme.hoverFill : AskClassic.sidebar }
}

/// A key drawn as a keycap, the way the launcher draws ⌘1…⌘9.
struct HelpKeycap: View {
    var key: String
    var large = false
    var pressed = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? (style.usesGlass ? 10 : 8) : style.help.keycapCorner,
                                     style: .continuous)
        Text(key)
            .font(.system(size: large ? 15 : 11.5, weight: large ? .medium : .regular))
            .foregroundStyle(large ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, large ? 13 : 5)
            .frame(minWidth: large ? 46 : 20, minHeight: large ? 46 : 20)
            .background(shape.fill(AskTheme.keycapSurface))
            .overlay(shape.strokeBorder(pressed ? AskTheme.accent : AskTheme.launcherShortcutEdge,
                                        lineWidth: pressed ? 1 : 0.5))
            .shadow(color: .black.opacity(large && !pressed ? 0.12 : 0), radius: 6, y: 3)
            .offset(y: pressed ? 2 : 0)
            .accessibilityHidden(true)
    }
}

/// A row of keycaps, or "Not set" when there are none.
struct HelpKeycaps: View {
    var keys: [String]?
    var onUnset: (() -> Void)?

    var body: some View {
        if let keys, !keys.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in HelpKeycap(key: key) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.joined(separator: " "))
        } else if let onUnset {
            Button(L("help.shortcuts.unset"), action: onUnset)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AskTheme.accentText)
        } else {
            Text(L("help.shortcuts.unset")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        }
    }
}

/// A launcher keyword in the launcher's grey label, with its aliases after it.
struct HelpKeywordLabel: View {
    var keyword: AskKeyword
    var showsAliases = true
    var large = false

    var body: some View {
        HStack(spacing: 5) {
            Text(keyword.keyword)
                .font(.system(size: large ? 13 : 12, design: .monospaced))
                .foregroundStyle(AskTheme.launcherKeywordText)
                .padding(.horizontal, large ? 8 : 6)
                .frame(minHeight: large ? 24 : 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AskTheme.launcherKeyword))
            if showsAliases, !keyword.aliases.isEmpty {
                Text(keyword.aliases.joined(separator: " · "))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// A group title above a block, with an optional link on the right.
struct HelpGroupTitle: View {
    var title: String
    var count: Int?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.textSecondary)
            if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary) }
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(AskTheme.accentText)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 18)
        .padding(.bottom, 7)
    }
}

/// Rows grouped in one rounded block with hairlines between them, like the settings window.
struct HelpBlock<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        VStack(spacing: 0) { content }
            .background(shape.fill(HelpTheme.blockFill(style)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(HelpTheme.blockBorder(style), lineWidth: 1))
    }
}

/// One row of a block: icon, title and detail, trailing content.
struct HelpRow<Trailing: View>: View {
    var symbol: String?
    var title: String
    var detail: String = ""
    var selected = false
    var dimmed = false
    var showsDivider = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
            }
            .opacity(dimmed ? 0.5 : 1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .background(background)
        .overlay(alignment: .top) {
            if showsDivider, !selected {
                Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.leading, symbol == nil ? 14 : 46)
            }
        }
        .contentShape(Rectangle())
        if let action {
            content.onTapGesture(perform: action).onHover { hovering = $0 }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var background: some View {
        if selected {
            Rectangle().fill(HelpTheme.selection(style))
                .overlay(Rectangle().strokeBorder(HelpTheme.selectionEdge(style), lineWidth: 1))
        } else if hovering {
            Rectangle().fill(AskTheme.hoverFill)
        }
    }
}

/// A plain or prominent button in the style's shape: a capsule on glass, a rounded rectangle in classic.
struct HelpButton: View {
    var title: String
    var symbol: String?
    var trailing: String?
    var prominent = false
    var action: () -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title)
                if let trailing { Text(trailing).opacity(0.75) }
            }
            .font(.system(size: 13))
            .foregroundStyle(prominent ? Color.white : StudioTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(shape.fill(prominent ? AskTheme.accent : AskTheme.pressFill))
            .overlay(shape.strokeBorder(prominent || style.usesGlass ? .clear : AskClassic.cardBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.usesGlass ? 14 : 6, style: .continuous)
    }
}
