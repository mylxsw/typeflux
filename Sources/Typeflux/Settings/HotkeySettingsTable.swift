import SwiftUI

/// A single-line name cell, with useful keyword names and actionable warnings.
struct HotkeySettingsName: View {
    let row: HotkeyRow
    let edit: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if case let .keyword(id) = row.target {
                Button {
                    edit(id)
                } label: {
                    HStack(spacing: 8) {
                        KeywordHotkeyBadge(keyword: row.title)
                        if let name = row.keywordName, name != row.title {
                            Text(name).font(.system(size: 13, weight: .medium))
                        }
                        Image(systemName: "pencil").font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("hotkeys.menu.edit"))
                .accessibilityLabel(L("hotkeys.keyword.sheet.editTitle") + " " + (row.keywordName ?? row.title))
                .accessibilityIdentifier("hotkeys.keyword.edit." + id.uuidString)
            } else {
                Image(systemName: row.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
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

/// Distinguishes a typed keyword from the action it runs.
struct KeywordHotkeyBadge: View {
    let keyword: String

    var body: some View {
        Text(keyword)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(StudioTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7).frame(minWidth: 36, minHeight: 24)
            .background(ModelVisualStyle.input,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(ModelVisualStyle.border))
    }
}
