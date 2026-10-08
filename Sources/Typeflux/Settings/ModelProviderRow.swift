import SwiftUI

/// Display data for one provider row, shared by the speech and language lists.
struct ModelProviderRowData: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: StudioModelProviderID
    let available: Bool
}

/// Grouped-list provider row: logo, name, detail line, connection state and disclosure chevron.
struct ModelProviderRow: View {
    let row: ModelProviderRowData
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ModelIconTile {
                    ModelProviderIcon(provider: row.icon, size: 22)
                }.opacity(row.available ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }.opacity(row.available ? 1 : 0.6)
                Spacer(minLength: 12)
                ModelConnectionStatus(connected: row.available)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 18).frame(minHeight: 60)
            .background(hovering ? StudioTheme.textPrimary.opacity(0.035) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
