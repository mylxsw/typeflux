import SwiftUI

/// Built-in destinations share the application's six-column rhythm.
struct AskLauncherFeatureTile: View {
    var row: AskLauncherHome.Row
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: row.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AskLauncherSuggestions.tint(row.tint))
                    .frame(width: 50, height: 50)
                    .background(AskLauncherSuggestions.tileFill(row.tint),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(AskTheme.accent, lineWidth: 3)
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
