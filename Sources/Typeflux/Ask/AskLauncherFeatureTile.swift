import SwiftUI

/// Built-in destinations share the application's six-column rhythm.
struct AskLauncherFeatureTile: View {
    @Environment(\.colorScheme) private var colorScheme
    var row: AskLauncherHome.Row
    var selected: Bool
    var action: () -> Void

    /// Muted inks stay readable on both appearances without neon system colors.
    static func ink(_ tint: AskLauncherHome.Tint, dark: Bool) -> Color {
        let rgb: (Double, Double, Double)
        switch tint {
        case .accent: rgb = dark ? (0.48, 0.67, 0.94) : (0.18, 0.38, 0.68)
        case .purple: rgb = dark ? (0.65, 0.61, 0.89) : (0.40, 0.34, 0.66)
        case .neutral: rgb = dark ? (0.59, 0.70, 0.76) : (0.30, 0.43, 0.49)
        case .red: rgb = dark ? (0.91, 0.56, 0.53) : (0.70, 0.29, 0.27)
        case .orange: rgb = dark ? (0.85, 0.69, 0.43) : (0.56, 0.39, 0.16)
        case .green: rgb = dark ? (0.55, 0.74, 0.64) : (0.27, 0.47, 0.36)
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    var body: some View {
        let ink = Self.ink(row.tint, dark: colorScheme == .dark)
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: row.symbol)
                    .font(.system(size: 23, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(ink)
                    .frame(width: 50, height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(AskTheme.launcherTile)
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(ink.opacity(colorScheme == .dark ? 0.09 : 0.06))
                            }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(AskTheme.launcherTileEdge, lineWidth: 0.5)
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(AskTheme.accent, lineWidth: 2)
                                .padding(-3)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text(row.title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: AskApplicationGrid.tileHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityHint(L("ask.home.hint.open"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
