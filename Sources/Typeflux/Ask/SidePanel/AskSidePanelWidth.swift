import CoreGraphics
import Foundation

/// The side panel's width beside the conversation. Dragging its leading edge changes it, and
/// the last width is kept for the next time the panel opens.
enum AskSidePanelWidth {
    /// The key the browser panel used before the side panel, so an existing width carries over.
    static let key = "ask.browser.panelWidth"
    static let defaultWidth: CGFloat = 560

    static func load(defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: key)
        return stored.isFinite && stored >= AskWorkspaceLayout.minimumDockedPanelWidth ? CGFloat(stored) : defaultWidth
    }

    static func save(_ width: CGFloat, defaults: UserDefaults = .standard) {
        guard width.isFinite, width >= AskWorkspaceLayout.minimumDockedPanelWidth else { return }
        defaults.set(Double(width.rounded()), forKey: key)
    }

    /// The width a drag asks for, kept between the panel's minimum and what leaves the
    /// conversation its minimum beside the panel (and the sidebar, when it shows).
    static func clamped(_ proposed: CGFloat, windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        let minimum = AskWorkspaceLayout.minimumDockedPanelWidth
        let maximum = max(minimum, windowWidth - sidebarWidth - AskWorkspaceLayout.minimumDockedContentWidth)
        return min(maximum, max(minimum, proposed))
    }
}
