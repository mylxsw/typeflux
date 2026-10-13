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
