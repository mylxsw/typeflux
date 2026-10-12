import SwiftUI

/// Tabs that switch between the Voice Input pages; the selected tab is underlined.
struct VoiceInputTabBar: View {
    let selection: StudioSection
    /// The count shown beside a tab, if it has one.
    var count: (StudioSection) -> Int? = { _ in nil }
    let onSelect: (StudioSection) -> Void

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.xxLarge) {
            ForEach(StudioSection.voiceInputCases) { section in
                StudioUnderlineTab(title: section.title, count: count(section), selected: section == selection) {
                    onSelect(section)
                }
                .accessibilityIdentifier("studio.voiceInput.tab.\(section.rawValue)")
            }
        }
    }
}
