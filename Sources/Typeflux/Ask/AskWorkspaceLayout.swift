import Foundation

/// Window geometry never changes the user's sidebar preference. Panels yield
/// space independently of height, which controls only the density of content.
struct AskWorkspaceLayout: Equatable {
    static let defaultWindowSize = CGSize(width: 1165, height: 886)
    static let minimumWindowSize = CGSize(width: 360, height: 280)
    static let comfortableContentWidth: CGFloat = 600

    let size: CGSize
    let sidebarCollapsed: Bool
    let showsUsage: Bool
    var rightPanelWidth: CGFloat? = nil

    var usageInline: Bool {
        showsUsage && size.width >= Self.comfortableContentWidth + usageWidth
    }

    var sidebarInline: Bool {
        !sidebarCollapsed && size.width - (usageInline ? usageWidth : 0)
            >= AskMetrics.sidebarWidth + Self.comfortableContentWidth
    }

    var mainWidth: CGFloat {
        max(0, size.width - (sidebarInline ? AskMetrics.sidebarWidth : 0) - (usageInline ? usageWidth : 0))
    }

    var compactContent: Bool { mainWidth < Self.comfortableContentWidth }
    var isShort: Bool { size.height < 500 }
    var isVeryShort: Bool { size.height < 360 }
    var horizontalInset: CGFloat { compactContent ? 14 : AskMetrics.columnInset }
    var composerWidth: CGFloat {
        min(AskMetrics.composerMaxWidth, max(0, mainWidth - (compactContent ? 24 : 44)))
    }
    var composerBottomInset: CGFloat { isShort ? 8 : AskMetrics.composerBottomInset }
    var composerTopInset: CGFloat { isShort ? 4 : 8 }
    var composerAvailableHeight: CGFloat {
        max(0, size.height - AskMetrics.titleBarRowHeight - composerTopInset - composerBottomInset)
    }
    /// Where the new page's headline and composer sit (GUL-464): together, a little
    /// above the middle, like ChatGPT's first screen.
    struct NewPagePlacement: Equatable {
        /// The headline's top, below the title bar.
        var headingTop: CGFloat
        /// How far the bottom-anchored composer moves up to sit under the headline.
        var composerLift: CGFloat
    }

    static let newPageGap: CGFloat = 26
    /// Above the exact middle reads as centred; ChatGPT's group sits a little high too.
    static let newPageBias: CGFloat = 0.42

    /// Nil when the window is short or the group does not fit: the composer then stays
    /// at the bottom, where it is in a conversation. `height` is the content column's own
    /// height, which can be less than the window's (the title bar's safe area).
    func newPagePlacement(heading: CGFloat, composer: CGFloat, height: CGFloat? = nil) -> NewPagePlacement? {
        let height = height ?? size.height
        guard !isShort, heading > 0, composer > 0, height > 0 else { return nil }
        let available = height - AskMetrics.titleBarRowHeight
        let group = heading + Self.newPageGap + composer
        guard group < available else { return nil }
        let headingTop = ((available - group) * Self.newPageBias).rounded()
        let composerTop = AskMetrics.titleBarRowHeight + headingTop + heading + Self.newPageGap
        let lift = height - composer - composerTop
        guard lift > 0 else { return nil }
        return NewPagePlacement(headingTop: headingTop, composerLift: lift)
    }

    var usageOverlay: Bool { showsUsage && !usageInline }
    var usageWidth: CGFloat { rightPanelWidth ?? AskMetrics.usagePanelWidth }
    var drawerWidth: CGFloat { min(usageWidth, max(0, size.width - 16)) }
    var usageOverlayTopInset: CGFloat {
        size.width - drawerWidth < AskMetrics.trafficLightInset ? AskMetrics.titleBarRowHeight - 8 : 0
    }
}
