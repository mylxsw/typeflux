import SwiftUI

/// Every group uses the same name, binding and control columns.
struct HotkeySettingsTableHeader: View {
    let group: HotkeyGroup
    let keyColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Text(L("hotkeys.column.name"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("studio.section.hotkeys"))
                .frame(width: keyColumnWidth, alignment: .leading)
            Text(group == .keywords ? L("ask.settings.keywords.enabled") : "")
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 44)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 14).frame(height: 30)
        .background(StudioTheme.controlSurface.opacity(0.45))
    }
}

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
