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
                VoiceInputTab(title: section.title, count: count(section), selected: section == selection) {
                    onSelect(section)
                }
                .accessibilityIdentifier("studio.voiceInput.tab.\(section.rawValue)")
            }
        }
    }
}

struct VoiceInputTab: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioTheme.Spacing.xxSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                if let count {
                    Text("\(count)")
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .lineLimit(1)
            .padding(.top, StudioTheme.Spacing.xxSmall)
            .padding(.bottom, StudioTheme.Spacing.small)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
