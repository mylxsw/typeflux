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
        TFListRow(title: row.name, subtitle: row.detail.isEmpty ? nil : row.detail, action: action) {
            TFLogoTile { ModelProviderIcon(provider: row.icon, size: 20) }
                .opacity(row.available ? 1 : 0.55)
        } accessory: {
            TFStatusLabel(text: L(row.available ? "models.configured" : "models.notConfigured"),
                          level: row.available ? .success : .neutral)
            TFChevron()
        }
    }
}
