import Foundation

/// The history column keeps its preferred width when narrow windows hide it.
enum AskSidebarWidth {
    static let key = "ask.sidebarWidth"
    static let minimum: CGFloat = 240
    static let maximum: CGFloat = 480

    static func normalized(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return AskMetrics.sidebarWidth }
        return min(maximum, max(minimum, width))
    }

    static func clamped(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(normalized(width), max(minimum, availableWidth - AskWorkspaceLayout.comfortableContentWidth))
    }
}
