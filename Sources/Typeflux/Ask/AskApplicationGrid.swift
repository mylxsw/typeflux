import SwiftUI

/// Shared geometry keeps home, search and arrow-key navigation in agreement.
enum AskApplicationGrid {
    static let columns = 6
    static let tileHeight: CGFloat = 106
    static let spacing: CGFloat = 8
    static var tracks: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
    }
    static func height(count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * spacing
    }
    static func move(_ index: Int, delta: Int, count: Int, horizontal: Bool = false) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index + delta * (horizontal ? 1 : columns)), count - 1)
    }
}

struct AskApplicationTile: View {
    var app: AskAppEntry
    var title: Text
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AskNativeIconView(icon: .init(kind: .file, value: app.url.path), symbol: "app",
                                  immediateLookup: false)
                    .id(app.iconFingerprint)
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)
                title.font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: AskApplicationGrid.tileHeight)
            .background(selected ? AskTheme.launcherSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.name)
        .accessibilityLabel(app.name)
        .accessibilityHint(L("ask.quick.app.open"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
