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
    var body: some View {
        TypefluxButton(kind: .borderless, action: action) {
            HStack(spacing: 8) {
                ModelProviderIcon(provider: row.icon, size: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.body).foregroundStyle(TypefluxColor.label.color)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                TypefluxStatus(L(row.available ? "models.configured" : "models.notConfigured"),
                               tone: row.available ? .success : .inactive)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }
        .accessibilityIdentifier("models.provider." + row.id)
    }
}
