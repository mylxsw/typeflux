import SwiftUI

/// Every background task, grouped by kind, plus what finished since launch.
struct BackgroundActivityWindowView: View {
    enum Tab: Hashable { case active, recent }

    @ObservedObject var center: BackgroundActivityCenter
    @State var tab: Tab = .active
    var now: () -> Date = Date.init

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .active: active
                    case .recent: recent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            TFDivider(inset: 0)
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(ModelVisualStyle.canvas)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TFSegmentedControl(options: [
                TFOption(.active, L("activity.window.active")),
                TFOption(.recent, L("activity.window.recent"))
            ], selection: $tab) { value in
                "activity.window.\(value == .active ? "active" : "recent")"
            }
            Spacer(minLength: 8)
            if tab == .recent, !center.recent.isEmpty {
                TFButton(title: L("activity.window.clear"), kind: .plain, size: .small) {
                    center.clearRecent()
                }
                .accessibilityIdentifier("activity.window.clear")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var active: some View {
        if center.activities.isEmpty {
            empty(L("activity.window.emptyActive"), symbol: "tray")
        } else {
            ForEach(BackgroundActivity.Kind.allCases, id: \.self) { kind in
                let items = center.activities.filter { $0.kind == kind }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        TFSectionHeader(title: Self.groupTitle(kind), count: items.count)
                        TFCard {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, activity in
                                if index > 0 { TFDivider(inset: 60) }
                                BackgroundActivityWindowRowView(activity: activity) {
                                    center.perform($0, on: activity.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if center.recent.isEmpty {
            empty(L("activity.window.emptyRecent"), symbol: "checkmark.circle")
        } else {
            TFCard {
                ForEach(Array(center.recent.enumerated()), id: \.element.id) { index, completion in
                    if index > 0 { TFDivider(inset: 56) }
                    HStack(spacing: 12) {
                        TFIconTile(systemImage: "checkmark", tint: TFColors.success, style: .soft)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(completion.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TFColors.textPrimary)
                                .lineLimit(1)
                            Text(Self.finished(completion, now: now()))
                                .font(.system(size: 11))
                                .foregroundStyle(TFColors.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 62)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L("activity.window.notifications"))
                .font(.system(size: 12))
                .foregroundStyle(TFColors.textSecondary)
            Spacer()
            TFSwitch(title: L("activity.window.notifications"), isOn: $center.notificationsEnabled)
                .accessibilityIdentifier("activity.window.notifications")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func empty(_ title: String, symbol: String) -> some View {
        TFEmptyState(systemImage: symbol, title: title) { EmptyView() }
            .frame(maxWidth: .infinity, minHeight: 240)
    }

    static func groupTitle(_ kind: BackgroundActivity.Kind) -> String {
        switch kind {
        case .agent: L("activity.group.agent")
        case .download: L("activity.group.download")
        case .index: L("activity.group.index")
        }
    }

    /// "Finished · 3 min. ago".
    static func finished(_ completion: BackgroundActivityCompletion, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .short
        let when = now.timeIntervalSince(completion.finishedAt) < 60
            ? L("activity.window.justNow")
            : formatter.localizedString(for: completion.finishedAt, relativeTo: now)
        return L("activity.window.finished", when)
    }
}

/// A roomier task row for the window; the menu keeps its compact row.
struct BackgroundActivityWindowRowView: View {
    let activity: BackgroundActivity
    let perform: (BackgroundActivity.Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            taskContent
            HStack(spacing: 4) {
                ForEach(orderedActions, id: \.self) { action in
                    actionButton(action)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(activity.title), \(activity.detail)"))
        .accessibilityIdentifier("activity.row.\(activity.id)")
    }

    @ViewBuilder private var taskContent: some View {
        if activity.route != nil {
            Button { perform(.open) } label: { taskLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(activity.title), \(activity.detail)"))
        } else {
            taskLabel
        }
    }

    private var taskLabel: some View {
        HStack(spacing: 12) {
            TFIconTile(systemImage: symbol, tint: tint, size: 32, style: .soft)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if activity.showsProgress { progress }
                Text(activity.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var progress: some View {
        if activity.state == .running && activity.progress == nil {
            ProgressView().progressViewStyle(.linear).tint(TFColors.accent)
        } else {
            ProgressView(value: activity.progress ?? 0)
                .progressViewStyle(.linear)
                .tint(activity.state == .running ? TFColors.accent : TFColors.textTertiary)
        }
    }

    @ViewBuilder private func actionButton(_ action: BackgroundActivity.Action) -> some View {
        if action == .retry || (action == .open && activity.state == .attention) {
            TFButton(title: BackgroundActivityRowView.label(action),
                     kind: activity.state == .attention ? .primary : .secondary, size: .small) {
                perform(action)
            }
            .accessibilityIdentifier("activity.action.\(action.rawValue)")
        } else {
            TFButton(title: BackgroundActivityRowView.label(action),
                     systemImage: BackgroundActivityRowView.symbol(action), kind: .secondary,
                     size: .small, iconOnly: true) {
                perform(action)
            }
            .accessibilityIdentifier("activity.action.\(action.rawValue)")
        }
    }

    private var symbol: String {
        switch activity.state {
        case .attention: "hand.raised.fill"
        case .failed: "exclamationmark"
        default:
            switch activity.kind {
            case .agent: "sparkles"
            case .download: "arrow.down"
            case .index: "doc.text.magnifyingglass"
            }
        }
    }

    private var tint: Color {
        switch activity.state {
        case .attention: TFColors.warning
        case .failed: TFColors.danger
        default: TFColors.accent
        }
    }

    private var detailColor: Color {
        switch activity.state {
        case .attention: TFColors.warning
        case .failed: TFColors.danger
        default: TFColors.textSecondary
        }
    }

    private var orderedActions: [BackgroundActivity.Action] {
        guard activity.state == .attention, activity.actions.contains(.open) else { return activity.actions }
        return activity.actions.filter { $0 != .open } + [.open]
    }
}
