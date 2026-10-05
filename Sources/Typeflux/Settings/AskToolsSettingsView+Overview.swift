import SwiftUI

/// The Overview tab: what Ask can use now, what needs fixing, and where new conversations are kept.
extension AskToolsSettingsView {
    @ViewBuilder var overviewSections: some View {
        let statuses = capabilityStatuses
        AgentOverviewSummary(statuses: statuses, noteCount: memoryNotes.notes.count) { status in
            navigate(to: status.capability)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ModelSectionLabel(title: L("ask.settings.local.title"))
                Text(L("agent.overview.storage.hint")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            HStack(alignment: .top, spacing: 12) {
                AgentStorageOption(
                    symbol: "cloud", title: Self.storageName(local: false), selected: !newConversationsStayLocal,
                    points: [(true, L("agent.storage.cloud.models")), (true, L("agent.storage.cloud.sync")),
                             (true, L("agent.storage.cloud.search")), (false, L("agent.storage.cloud.credits"))]
                ) { setNewConversationsStayLocal(false) }
                AgentStorageOption(
                    symbol: "lock", title: Self.storageName(local: true), selected: newConversationsStayLocal,
                    points: [(true, L("agent.storage.local.private")), (true, L("agent.storage.local.models")),
                             (false, L("agent.storage.local.search")), (false, L("agent.storage.local.limits"))]
                ) { setNewConversationsStayLocal(true) }
            }
            Text(L("agent.overview.storage.footnote"))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("agent.overview.capabilities"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                      alignment: .leading, spacing: 12) {
                ForEach(statuses) { status in
                    AgentCapabilityCard(status: status) { navigate(to: status.capability) }
                }
            }
        }
    }

    func navigate(to capability: AgentCapability) {
        let destination = capability.destination
        if let extensions = destination.extensions { extensionsTab.wrappedValue = extensions }
        onNavigate(destination.tab, destination.extensions)
    }
}

/// Headline count of usable capabilities and a shortcut to the first one needing attention.
struct AgentOverviewSummary: View {
    let statuses: [AgentCapabilityStatus]
    let noteCount: Int
    let onFix: (AgentCapabilityStatus) -> Void

    private var attention: [AgentCapabilityStatus] {
        statuses.filter { $0.level == .attention }
    }

    var detail: String {
        var parts = [attention.isEmpty
            ? L("agent.overview.allSet")
            : L("agent.overview.needsAttention", attention.count, attention.map(\.capability.title).joined(separator: L("agent.listSeparator")))]
        if noteCount > 0 { parts.append(L("agent.overview.notes", noteCount)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("agent.overview.ready", statuses.filter { $0.level == .ready }.count))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let first = attention.first {
                Button(L("agent.overview.fix")) { onFix(first) }.buttonStyle(ModelActionStyle(primary: true))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(
            LinearGradient(colors: [ModelVisualStyle.accent.opacity(0.14), ModelVisualStyle.surface],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
            .strokeBorder(ModelVisualStyle.border))
    }
}

/// One choice of where new conversations are kept, listing what it allows and what it gives up.
struct AgentStorageOption: View {
    let symbol: String
    let title: String
    let selected: Bool
    let points: [(included: Bool, text: String)]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 14))
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? ModelVisualStyle.accent : StudioTheme.textTertiary)
                }
                .foregroundStyle(StudioTheme.textPrimary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: point.included ? "checkmark" : "minus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(point.included ? StudioTheme.success : StudioTheme.textTertiary)
                                .frame(width: 12)
                            Text(point.text).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(ModelVisualStyle.surface,
                        in: RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
                .strokeBorder(selected ? ModelVisualStyle.accent : ModelVisualStyle.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Overview card for one capability; opens its settings.
struct AgentCapabilityCard: View {
    let status: AgentCapabilityStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: status.capability.symbol).font(.system(size: 14))
                        .foregroundStyle(status.level == .off ? StudioTheme.textTertiary : ModelVisualStyle.accent)
                        .frame(width: 30, height: 30)
                        .background(status.level == .off ? StudioTheme.iconTileSurface : ModelVisualStyle.accent.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(status.capability.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                }
                Text(status.capability.summary).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                HStack {
                    AgentStatusBadge(level: status.level, label: status.label)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(ModelVisualStyle.surface,
                        in: RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
                .strokeBorder(ModelVisualStyle.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(status.capability.title), \(status.label)")
    }
}
