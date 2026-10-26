import SwiftUI

/// Both bundled icon families use the application's seven-column rhythm.
struct AskLauncherFeatureTile: View {
    @AppStorage(AskLauncherFeatureIcons.preferenceKey) private var iconStyle = AskLauncherFeatureIcons.Style.sculpted
    var row: AskLauncherHome.Row
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                artwork
                    .frame(width: 56, height: 56)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(AskTheme.accent, lineWidth: 2)
                                .frame(width: 54, height: 54)
                        }
                    }
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

    @ViewBuilder private var artwork: some View {
        if let image = AskLauncherFeatureIcons.image(for: row.id, style: iconStyle) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: row.symbol).font(.system(size: 23, weight: .medium))
                .foregroundStyle(AskLauncherSuggestions.tint(row.tint))
        }
    }
}
