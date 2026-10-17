import AppKit
import SwiftUI

/// Which tasks the menu shows. Fixed while the menu is open, because a menu
/// that changes height under the pointer jumps; the rows themselves stay live.
struct BackgroundActivityMenuLayout: Equatable {
    static let rowLimit = 4
    static let width: CGFloat = 320
    static let headerHeight: CGFloat = 24
    static let moreHeight: CGFloat = 24
    static let verticalPadding: CGFloat = 4

    var rows: [String]
    /// Titles of the rows, kept for a task that ends while the menu is open.
    var titles: [String: String]
    var hiddenCount: Int

    @MainActor init(activities: [BackgroundActivity]) {
        let visible = activities.filter(Self.showsInMenu)
        let shown = visible.prefix(Self.rowLimit)
        rows = shown.map(\.id)
        titles = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.title) })
        hiddenCount = max(0, visible.count - Self.rowLimit)
    }

    @MainActor static func showsInMenu(_ activity: BackgroundActivity) -> Bool {
        activity.id != ContentIndexActivitySource.indexID ||
            (activity.state != .paused && activity.state != .waiting)
    }

    var isEmpty: Bool {
        rows.isEmpty
    }

    var height: CGFloat {
        Self.verticalPadding * 2 + Self.headerHeight + CGFloat(rows.count) * BackgroundActivityRowView.height
            + (hiddenCount > 0 ? Self.moreHeight : 0)
    }
}

struct BackgroundActivityMenuSection: View {
    @ObservedObject var center: BackgroundActivityCenter
    let layout: BackgroundActivityMenuLayout
    let perform: (BackgroundActivity.Action, String) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("activity.menu.showAll"), action: showAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("activity.menu.showAll")
            }
            .padding(.horizontal, 10)
            .frame(height: BackgroundActivityMenuLayout.headerHeight)
            ForEach(layout.rows, id: \.self) { id in
                if let activity = center.activity(id) {
                    if BackgroundActivityMenuLayout.showsInMenu(activity) {
                        BackgroundActivityRowView(activity: activity) { perform($0, id) }
                    }
                } else {
                    ended(layout.titles[id] ?? "")
                }
            }
            if layout.hiddenCount > 0 {
                Button(action: showAll) {
                    Text(L("activity.menu.more", layout.hiddenCount))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                }
                .buttonStyle(.plain)
                .frame(height: BackgroundActivityMenuLayout.moreHeight)
                .accessibilityIdentifier("activity.menu.more")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, BackgroundActivityMenuLayout.verticalPadding)
        .frame(width: BackgroundActivityMenuLayout.width, height: layout.height, alignment: .top)
    }

    private var header: String {
        let active = center.activeCount
        return active > 0 ? L("activity.menu.headerActive", active) : L("activity.menu.header")
    }

    private func ended(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.green.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(L("activity.menu.ended")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: BackgroundActivityRowView.height)
    }
}

extension BackgroundActivityMenuSection {
    /// A menu item hosting the section, sized for its layout.
    static func menuItem(center: BackgroundActivityCenter, layout: BackgroundActivityMenuLayout,
                         perform: @escaping (BackgroundActivity.Action, String) -> Void,
                         showAll: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: BackgroundActivityMenuSection(
            center: center, layout: layout, perform: perform, showAll: showAll
        ))
        view.frame = NSRect(x: 0, y: 0, width: BackgroundActivityMenuLayout.width, height: layout.height)
        item.view = view
        view.setAccessibilityIdentifier("activity.menu.section")
        return item
    }
}
