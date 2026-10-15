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
