import SwiftUI

/// Building blocks of the Agent settings page. They reuse the Models page surfaces
/// (section caption, list card, icon tile, inset dividers) so both pages read as one design.
struct AgentSettingsSection<Content: View>: View {
    let title: String
    var detail: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: title, detail: detail)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) { content }
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Icon tile, title, optional detail and a trailing control, matching the Models scene rows.
struct AgentSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var badge: String?
    var subtitleLineLimit: Int? = 2
    var titleLineLimit: Int? = 1
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            ModelIconTile {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(StudioTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(titleLineLimit)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge { ModelUsageBadge(text: badge) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(minHeight: 68)
    }
}

extension AgentSettingsRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, badge: String? = nil, subtitleLineLimit: Int? = 2) {
        self.init(icon: icon, title: title, subtitle: subtitle, badge: badge,
                  subtitleLineLimit: subtitleLineLimit) { EmptyView() }
    }
}

/// Accent row that adds an item to the card above it, like "Add endpoint" on the Models page.
struct AgentSettingsActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ModelVisualStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        ModelVisualStyle.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Text(title).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ModelVisualStyle.accent)
                Spacer()
            }
            .padding(.horizontal, 18).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Muted single-line placeholder shown inside an empty card.
struct AgentSettingsEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 18)
    }
}

/// Borderless trailing icon button, e.g. remove a folder or note.
struct AgentSettingsIconButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    ModelVisualStyle.control,
                    in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
