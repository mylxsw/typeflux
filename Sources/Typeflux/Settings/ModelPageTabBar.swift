import SwiftUI

/// Tabs that switch between the Models page's tabs; they look like the Voice Input tabs.
struct ModelPageTabBar: View {
    let selection: ModelPageTab
    let onSelect: (ModelPageTab) -> Void

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.xxLarge) {
            ForEach(ModelPageTab.allCases) { tab in
                VoiceInputTab(title: tab.title, count: nil, selected: tab == selection) {
                    onSelect(tab)
                }
                .accessibilityIdentifier("studio.models.tab.\(tab.rawValue)")
            }
        }
    }
}
