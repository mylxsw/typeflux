import SwiftUI

struct StudioInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? StudioTheme.Opacity.pressedFade : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StudioShell<Content: View>: View {
    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void
    let searchText: Binding<String>
    let searchPlaceholder: String
    let content: Content

    init(
        currentSection: StudioSection,
        onSelect: @escaping (StudioSection) -> Void,
        searchText: Binding<String>,
        searchPlaceholder: String,
        @ViewBuilder content: () -> Content
    ) {
        self.currentSection = currentSection
        self.onSelect = onSelect
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.content = content()
    }

    var body: some View {
        ZStack {
            StudioTheme.windowBackground
                .ignoresSafeArea()

            HStack(spacing: StudioTheme.Spacing.none) {
                StudioSidebar(currentSection: currentSection, onSelect: onSelect)
                    .frame(width: StudioTheme.sidebarWidth)

                ScrollView {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.section) {
                        content
                    }
                    .frame(maxWidth: StudioTheme.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, StudioTheme.contentInset)
                    .padding(.top, StudioTheme.Layout.shellContentTopInset)
                    .padding(.bottom, StudioTheme.Layout.shellContentBottomInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(
                    RoundedRectangle(cornerRadius: StudioTheme.Layout.shellCornerRadius, style: .continuous)
                        .fill(StudioTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.Layout.shellCornerRadius, style: .continuous)
                        .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.shellBorder), lineWidth: StudioTheme.BorderWidth.thin)
                )
                .padding(.vertical, StudioTheme.Layout.contentCardInset)
                .padding(.trailing, StudioTheme.Layout.contentCardInset)
                .padding(.leading, StudioTheme.Layout.shellContentLeadingInset)
            }
            .padding(StudioTheme.Layout.shellInset)
        }
    }
}

struct StudioSidebar: View {
    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(spacing: StudioTheme.Spacing.smallMedium) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: StudioTheme.Typography.iconMediumLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.sidebarHeaderText) {
                    Text("VoiceInput")
                        .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("Desktop")
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

                Spacer()
            }
            .padding(.top, StudioTheme.Insets.sidebarHeaderTop)

            VStack(spacing: StudioTheme.Spacing.xxSmall) {
                ForEach(StudioSection.allCases) { section in
                    Button(action: { onSelect(section) }) {
                        HStack(spacing: StudioTheme.Spacing.medium) {
                            Image(systemName: section.iconName)
                                .font(.system(size: StudioTheme.Typography.iconRegular, weight: .medium))
                                .frame(width: StudioTheme.ControlSize.sidebarNavigationIcon)

                            Text(section.title)
                                .font(.studioBody(StudioTheme.Typography.body, weight: .medium))

                            Spacer()
                        }
                        .foregroundStyle(section == currentSection ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .padding(.horizontal, StudioTheme.Insets.sidebarItemHorizontal)
                        .padding(.vertical, StudioTheme.Insets.sidebarItemVertical)
                        .background(
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                                .fill(section == currentSection ? StudioTheme.Colors.white.opacity(StudioTheme.Opacity.sidebarSelectionFill) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                }
            }

            Spacer()
        }
        .padding(.horizontal, StudioTheme.Insets.sidebarOuterHorizontal)
        .padding(.vertical, StudioTheme.Insets.sidebarOuterVertical)
    }
}

struct StudioHeroHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            Text(title)
                .font(.studioDisplay(StudioTheme.Typography.heroTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(subtitle)
                .font(.studioBody(StudioTheme.Typography.bodyLarge))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(maxWidth: StudioTheme.Layout.heroMaxWidth, alignment: .leading)
        }
    }
}

struct StudioSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
            .foregroundStyle(StudioTheme.textSecondary)
    }
}

struct StudioCard<Content: View>: View {
    var padding: CGFloat = StudioTheme.Insets.cardDefault
    let content: Content

    init(padding: CGFloat = StudioTheme.Insets.cardDefault, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardCompact) {
            content
        }
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }
}

struct StudioButton: View {
    enum Variant {
        case primary
        case secondary
        case ghost
    }

    let title: String
    let systemImage: String?
    let variant: Variant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                }
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            }
            .padding(.horizontal, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonVertical)
            .frame(minWidth: variant == .ghost ? nil : StudioTheme.ControlSize.buttonMinWidth)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .foregroundStyle(foreground)
        .background(background)
        .overlay(overlay)
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.accent)
        case .secondary:
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.surfaceMuted)
        case .ghost:
            Color.clear
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if variant != .ghost {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .stroke(variant == .primary ? Color.clear : StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            return .white
        case .secondary:
            return StudioTheme.textPrimary
        case .ghost:
            return StudioTheme.textSecondary
        }
    }
}

struct StudioPill: View {
    let title: String
    var tone: Color = StudioTheme.textSecondary
    var fill: Color = StudioTheme.surfaceMuted

    var body: some View {
        Text(title)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, StudioTheme.Insets.pillHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical)
            .background(Capsule().fill(fill))
    }
}

struct StudioMetricCard: View {
    let icon: String
    let value: String
    let caption: String
    let badge: String?

    var body: some View {
        StudioCard {
            HStack(alignment: .center) {
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .fill(StudioTheme.surfaceMuted)
                    .frame(width: StudioTheme.ControlSize.overviewBadge, height: StudioTheme.ControlSize.overviewBadge)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: StudioTheme.Typography.iconRegular, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)
                    )

                Spacer()

                if let badge {
                    StudioPill(title: badge)
                }
            }

            Text(value)
                .font(.studioDisplay(StudioTheme.Typography.heroMetric, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(caption)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.compactMetricMinHeight, alignment: .leading)
    }
}

struct StudioSettingRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: StudioTheme.Spacing.pageGroup)
            accessory
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
    }
}

struct StudioTextInputCard: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            Text(label)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)

            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.studioBody(StudioTheme.Typography.bodyLarge))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
            .padding(.vertical, StudioTheme.Insets.textFieldVertical)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
            )
        }
    }
}

struct StudioHistoryRow: View {
    let record: HistoryPresentationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.smallMedium) {
                Text(record.timestampText)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)

                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.historyBadge, style: .continuous)
                    .fill(record.accentColor.opacity(StudioTheme.Opacity.historyAccent))
                    .frame(width: StudioTheme.ControlSize.historyBadge, height: StudioTheme.ControlSize.historyBadge)
                    .overlay(
                        Image(systemName: record.accentName)
                            .font(.system(size: StudioTheme.Typography.iconTiny, weight: .semibold))
                            .foregroundStyle(record.accentColor)
                    )

                Text(record.sourceName)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()
            }

            Text(record.previewText)
                .font(.studioBody(StudioTheme.Typography.bodyLarge))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, StudioTheme.Insets.historyRowHorizontal)
        .padding(.vertical, StudioTheme.Insets.historyRowVertical)
        .background(StudioTheme.surface)
    }
}

private extension HistoryPresentationRecord {
    var accentColor: Color {
        switch accentColorName {
        case "purple":
            return StudioTheme.Colors.historyPurple.opacity(StudioTheme.Opacity.historyAccentStrong)
        case "green":
            return StudioTheme.Colors.historyGreen.opacity(StudioTheme.Opacity.historyAccentStrong)
        case "orange":
            return StudioTheme.Colors.historyOrange.opacity(StudioTheme.Opacity.historyAccentStrong)
        default:
            return StudioTheme.accent
        }
    }
}
