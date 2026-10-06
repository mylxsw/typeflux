import SwiftUI

/// One entry in a settings page's pane list.
protocol SettingsPaneItem: Hashable, Identifiable {
    var title: String { get }
    var symbol: String { get }
}

enum SettingsPaneMetrics {
    static let listWidth: CGFloat = 208
    static let spacing: CGFloat = 28
    /// Below this content width the pane list folds into a menu above the pane.
    static let compactWidth: CGFloat = 720

    static func isCompact(contentWidth: CGFloat) -> Bool {
        contentWidth < compactWidth
    }
}

/// A grouped pane list beside the selected pane, or a menu above it when space is short.
struct SettingsPaneLayout<Pane: SettingsPaneItem, Detail: View>: View {
    let sections: [(title: String?, panes: [Pane])]
    @Binding var selection: Pane
    var compact = false
    /// State shown next to a pane, if it has one.
    var status: (Pane) -> AgentCapabilityStatus? = { _ in nil }
    @ViewBuilder var detail: Detail

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPaneMenu(sections: sections, selection: $selection, status: status)
                detail
            }
        } else {
            HStack(alignment: .top, spacing: SettingsPaneMetrics.spacing) {
                SettingsPaneList(sections: sections, selection: $selection, status: status)
                    .frame(width: SettingsPaneMetrics.listWidth)
                VStack(alignment: .leading, spacing: 24) { detail }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Grouped list of panes; each row shows the pane's state as a dot and one line.
struct SettingsPaneList<Pane: SettingsPaneItem>: View {
    let sections: [(title: String?, panes: [Pane])]
    @Binding var selection: Pane
    var status: (Pane) -> AgentCapabilityStatus? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if let title = section.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 0 : 14).padding(.bottom, 4)
                }
                ForEach(section.panes) { pane in
                    SettingsPaneRow(pane: pane, selected: pane == selection, status: status(pane)) {
                        selection = pane
                    }
                }
            }
        }
    }
}

struct SettingsPaneRow<Pane: SettingsPaneItem>: View {
    let pane: Pane
    let selected: Bool
    let status: AgentCapabilityStatus?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? ModelVisualStyle.accent : StudioTheme.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .lineLimit(1)
                    if let status {
                        Text(status.label)
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let status {
                    AgentStatusDot(level: status.level)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? ModelVisualStyle.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.map { "\(pane.title), \($0.label)" } ?? pane.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pane list as a menu, for narrow windows.
struct SettingsPaneMenu<Pane: SettingsPaneItem>: View {
    let sections: [(title: String?, panes: [Pane])]
    @Binding var selection: Pane
    var status: (Pane) -> AgentCapabilityStatus? = { _ in nil }

    var body: some View {
        Menu {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section.panes) { pane in
                    Button {
                        selection = pane
                    } label: {
                        Label(status(pane).map { "\(pane.title) · \($0.label)" } ?? pane.title, systemImage: pane.symbol)
                    }
                }
            }
        } label: {
            Label(selection.title, systemImage: selection.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Small coloured dot for a capability state.
struct AgentStatusDot: View {
    let level: AgentCapabilityStatus.Level

    var body: some View {
        Circle()
            .fill(color.opacity(level == .off ? 0.5 : 1))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch level {
        case .ready: StudioTheme.success
        case .attention: StudioTheme.warning
        case .off: StudioTheme.textTertiary
        }
    }
}
