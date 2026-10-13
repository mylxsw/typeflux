import SwiftUI

/// Presentation state and actions shared by the workspace's toolbar, composer and drawers.
@MainActor
final class AskWorkspaceState: ObservableObject {
    @Published var showsUsage: Bool
    @Published var usageRunId: String?
    @Published var sidebarChoice: Bool?
    @Published var showsSidebarDrawer = false
    @Published var isSearching = false
    @Published private(set) var composerFocusRequestID: UUID?

    func focusComposer() { composerFocusRequestID = UUID() }

    init(showsUsage: Bool = false, runId: String? = nil) {
        self.showsUsage = showsUsage
        usageRunId = runId
    }

    func toggleSidebar(layout: AskWorkspaceLayout, collapsed: Bool, reduceMotion: Bool,
                       persist: (Bool) -> Void) {
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            if !layout.sidebarInline,
               layout.size.width - (layout.usageInline ? layout.usageWidth : 0)
               < AskMetrics.sidebarWidth + AskWorkspaceLayout.comfortableContentWidth {
                if layout.usageOverlay { showsUsage = false }
                showsSidebarDrawer.toggle()
            } else {
                sidebarChoice = !collapsed
                persist(!collapsed)
            }
        }
    }

    func toggleUsage(runId: String?, reduceMotion: Bool) {
        if !showsUsage { usageRunId = runId }
        setUsage(!showsUsage, reduceMotion: reduceMotion)
    }

    func setUsage(_ shown: Bool, reduceMotion: Bool) {
        guard shown != showsUsage else { return }
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            showsSidebarDrawer = false
            isSearching = false
            showsUsage = shown
        }
    }

    func closeDrawer(reduceMotion: Bool, closeWorkflow: () -> Void) {
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            if !showsSidebarDrawer {
                showsUsage = false
                closeWorkflow()
            }
            showsSidebarDrawer = false
        }
    }

    func openSearch(reduceMotion: Bool, closeWorkflow: () -> Void) {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) {
            closeDrawer(reduceMotion: reduceMotion, closeWorkflow: closeWorkflow)
            isSearching = true
        }
    }
}

private struct AskComposerFocusRequestKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var askComposerFocusRequest: UUID? {
        get { self[AskComposerFocusRequestKey.self] }
        set { self[AskComposerFocusRequestKey.self] = newValue }
    }
}
