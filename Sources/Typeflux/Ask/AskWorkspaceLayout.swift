import Foundation

/// Window geometry never changes the user's sidebar preference. Panels yield
/// space independently of height, which controls only the density of content.
struct AskWorkspaceLayout: Equatable {
    static let minimumWindowSize = CGSize(width: 360, height: 280)
    static let comfortableContentWidth: CGFloat = 600

    let size: CGSize
    let sidebarCollapsed: Bool
    let showsUsage: Bool

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
    var usageOverlay: Bool { showsUsage && !usageInline }
    var usageWidth: CGFloat { AskMetrics.usagePanelWidth + AskMetrics.sidebarPanelInset }
    var drawerWidth: CGFloat { min(usageWidth, max(0, size.width - 16)) }
    var usageOverlayTopInset: CGFloat {
        size.width - drawerWidth < AskMetrics.trafficLightInset ? AskMetrics.titleBarRowHeight - 8 : 0
    }
}
