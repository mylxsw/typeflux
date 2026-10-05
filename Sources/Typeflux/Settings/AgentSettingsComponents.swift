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

/// Coloured pill describing whether a capability is ready, needs attention or is off.
struct AgentStatusBadge: View {
    let level: AgentCapabilityStatus.Level
    let label: String

    private var color: Color {
        switch level {
        case .ready: StudioTheme.success
        case .attention: StudioTheme.warning
        case .off: StudioTheme.textSecondary
        }
    }

    var body: some View {
        Text(label).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(level == .off ? 0.09 : 0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// A short rule such as "No network", shown in place of an explanatory paragraph.
struct AgentFactChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(text).font(.system(size: 11.5))
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(StudioTheme.textSecondary.opacity(0.09), in: Capsule())
        .fixedSize()
    }
}

/// Lays out children left to right, wrapping onto new lines when the width runs out.
struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Search box styled like the Models page fields, with a leading magnifier.
struct AgentSearchBox: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.clear"))
            }
        }
        .padding(.horizontal, 10).frame(width: 240, height: 30)
        .background(ModelVisualStyle.control,
                    in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
            .strokeBorder(ModelVisualStyle.border))
    }
}

/// Page-level tabs with an accent underline; a dot marks tabs with something to fix.
struct AgentUnderlineTabs<Value: Hashable>: View {
    let options: [(label: String, value: Value, needsAttention: Bool)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        if option.needsAttention {
                            Circle().fill(StudioTheme.warning).frame(width: 6, height: 6)
                                .accessibilityLabel(L("agent.status.needsAttention"))
                        }
                    }
                    .padding(.bottom, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? ModelVisualStyle.accent : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(ModelVisualStyle.divider).frame(height: 1) }
    }
}

/// Centered explanation shown in a card that has nothing to list yet.
struct AgentEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20))
                .foregroundStyle(ModelVisualStyle.accent)
                .frame(width: 46, height: 46)
                .background(ModelVisualStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            Text(message).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30).padding(.horizontal, 20)
    }
}

/// Confirms a removal and offers to undo it for a few seconds.
struct AgentUndoBanner: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    var duration: Duration = .seconds(5)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle").foregroundStyle(StudioTheme.textSecondary)
            Text(message).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            Button(L("agent.undo"), action: onUndo).buttonStyle(ModelActionStyle())
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ModelVisualStyle.border))
        .task(id: message) {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { onDismiss() }
        }
    }
}
