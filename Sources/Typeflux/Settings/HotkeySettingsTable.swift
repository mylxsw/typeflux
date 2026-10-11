import SwiftUI

/// A single-line name cell, with useful keyword names and actionable warnings.
struct HotkeySettingsName: View {
    let row: HotkeyRow
    let edit: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.icon)
                .font(.system(size: 14))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            if case let .keyword(id) = row.target {
                Button {
                    edit(id)
                } label: {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        if let name = row.keywordName, name != row.title {
                            Text(name).font(.system(size: 13))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.keywordName ?? row.title)
            } else {
                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            if let status = row.status, status != .disabled, status != .unset,
               let message = HotkeySettingsPresentation.statusMessage(status) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.warning)
                    .help(message)
                    .accessibilityLabel(message)
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
    }
}
