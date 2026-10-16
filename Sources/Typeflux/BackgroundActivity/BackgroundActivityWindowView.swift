import SwiftUI

/// Every background task, grouped by kind, plus what finished since launch.
struct BackgroundActivityWindowView: View {
    enum Tab: Hashable { case active, recent }

    @ObservedObject var center: BackgroundActivityCenter
    @State var tab: Tab = .active
    var now: () -> Date = Date.init

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L("activity.window.active")).tag(Tab.active)
                Text(L("activity.window.recent")).tag(Tab.recent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .active: active
                    case .recent: recent
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    @ViewBuilder private var active: some View {
        if center.activities.isEmpty {
            empty(L("activity.window.emptyActive"))
        } else {
            ForEach(BackgroundActivity.Kind.allCases, id: \.self) { kind in
                let items = center.activities.filter { $0.kind == kind }
                if !items.isEmpty {
                    groupTitle("\(Self.groupTitle(kind)) · \(items.count)")
                    ForEach(items) { activity in
                        BackgroundActivityRowView(activity: activity, revealsActionsOnHover: false) {
                            center.perform($0, on: activity.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if center.recent.isEmpty {
            empty(L("activity.window.emptyRecent"))
        } else {
            HStack {
                Spacer()
                Button(L("activity.window.clear")) { center.clearRecent() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ForEach(center.recent) { completion in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.green.opacity(0.16))
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(completion.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(Self.finished(completion, now: now()))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: BackgroundActivityRowView.height)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle(L("activity.window.notifications"), isOn: $center.notificationsEnabled)
            Spacer()
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)
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
