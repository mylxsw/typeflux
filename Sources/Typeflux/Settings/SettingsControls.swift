import SwiftUI

/// A quiet caption above settings lists, with an optional nearby disclosure arrow.
struct SettingsListSectionLabel: View {
    let title: String
    var count: Int?
    var expanded: Bool?

    var body: some View {
        HStack(spacing: 7) {
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
            if let count {
                Text(L("settings.list.itemCount", count))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 4)
        .frame(minHeight: SettingsControlMetrics.height)
    }
}

/// Settings action chrome with optional progress, shared by provider configuration actions.
struct SettingsActionButton: View {
    let title: String
    var symbol: String?
    var primary = false
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        TypefluxButton(kind: primary ? .primary : .regular, action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
        }
        .accessibilityLabel(title)
        .disabled(isDisabled || isLoading)
    }
}
