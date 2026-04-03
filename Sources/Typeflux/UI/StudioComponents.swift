import AppKit
import SwiftUI

struct StudioInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? StudioTheme.Opacity.pressedFade : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct StudioButtonChromeModifier: ViewModifier {
    let variant: StudioButton.Variant
    let isDisabled: Bool
    let isLoading: Bool
    let isPressed: Bool
    let minWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minWidth)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(overlay)
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
            .scaleEffect(isPressed ? 0.985 : 1)
            .opacity(opacity)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: isLoading)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.accent)
                .brightness(isPressed ? -0.06 : (isLoading ? -0.03 : 0))
        case .secondary:
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.surfaceMuted)
                .brightness(isPressed ? -0.03 : (isLoading ? -0.015 : 0))
        case .ghost:
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(isPressed ? StudioTheme.surfaceMuted.opacity(0.52) : (isLoading ? StudioTheme.surfaceMuted.opacity(0.28) : Color.clear))
        }
    }

    @ViewBuilder
    private var overlay: some View {
        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
            .stroke(borderColor, lineWidth: borderWidth)
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

    private var borderColor: Color {
        switch variant {
        case .primary:
            return Color.clear
        case .secondary, .ghost:
            return StudioTheme.border.opacity(isPressed || isLoading ? 0.82 : 1)
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .ghost:
            return isPressed || isLoading ? StudioTheme.BorderWidth.thin : 0
        case .primary, .secondary:
            return StudioTheme.BorderWidth.thin
        }
    }

    private var opacity: Double {
        if isDisabled { return 0.72 }
        return 1
    }
}

private struct StudioButtonChrome<Label: View>: View {
    let variant: StudioButton.Variant
    let isDisabled: Bool
    let isLoading: Bool
    let minWidth: CGFloat?
    let action: () -> Void
    let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        Button {
            isPressed = true
            action()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                isPressed = false
            }
        } label: {
            label()
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(StudioInteractiveButtonStyle())
        .modifier(
            StudioButtonChromeModifier(
                variant: variant,
                isDisabled: isDisabled || isLoading,
                isLoading: isLoading,
                isPressed: isPressed,
                minWidth: minWidth
            )
        )
    }
}

struct StudioShell<Content: View>: View {
    let currentSection: StudioSection
    let onSelect: (StudioSection) -> Void
    let onOpenAbout: () -> Void
    let onSendFeedback: () -> Void
    let searchText: Binding<String>
    let searchPlaceholder: String
    let agentEnabled: Bool
    let content: (CGSize) -> Content

    init(
        currentSection: StudioSection,
        onSelect: @escaping (StudioSection) -> Void,
        onOpenAbout: @escaping () -> Void,
        onSendFeedback: @escaping () -> Void,
        searchText: Binding<String>,
        searchPlaceholder: String,
        agentEnabled: Bool = false,
        @ViewBuilder content: @escaping (CGSize) -> Content
    ) {
        self.currentSection = currentSection
        self.onSelect = onSelect
        self.onOpenAbout = onOpenAbout
        self.onSendFeedback = onSendFeedback
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.agentEnabled = agentEnabled
        self.content = content
    }

    var body: some View {
        ZStack {
            StudioTheme.windowBackground
                .ignoresSafeArea()

            HStack(spacing: StudioTheme.Spacing.none) {
                StudioSidebar(
                    currentSection: currentSection,
                    onSelect: onSelect,
                    onSendFeedback: onSendFeedback,
                    onOpenAbout: onOpenAbout,
                    agentEnabled: agentEnabled
                )
                    .frame(width: StudioTheme.sidebarWidth)

                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.section) {
                            content(proxy.size)
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
                }
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
    let onSendFeedback: () -> Void
    let onOpenAbout: () -> Void
    let agentEnabled: Bool
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.smallMedium) {
                Image(systemName: StudioTheme.Symbol.brand)
                    .font(.system(size: StudioTheme.Typography.iconLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("sidebar.appName"))
                        .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("Beta")
                        .font(.studioBody(7, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(StudioTheme.textSecondary.opacity(0.55))
                        .baselineOffset(6)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer()
            }
            .padding(.top, StudioTheme.Insets.sidebarHeaderTop)

            VStack(spacing: StudioTheme.Spacing.xxSmall) {
                ForEach(StudioSection.sidebarUpperCases, id: \.self) { section in
                    sidebarNavigationButton(for: section)
                }
            }

            Spacer()

            VStack(spacing: StudioTheme.Spacing.xxSmall) {
                ForEach(StudioSection.sidebarLowerCases, id: \.self) { section in
                    sidebarNavigationButton(for: section)
                }

                if agentEnabled {
                    sidebarNavigationButton(for: .agent)
                }
            }

            Rectangle()
                .fill(StudioTheme.border.opacity(0.5))
                .frame(height: 1)

            HStack(spacing: StudioTheme.Spacing.none) {
                HStack(spacing: StudioTheme.Spacing.smallMedium) {
                    StudioSidebarIconButton(
                        systemImage: "envelope",
                        accessibilityLabel: L("sidebar.feedbackAccessibility"),
                        action: onSendFeedback
                    )

                    StudioSidebarIconButton(
                        systemImage: "questionmark.circle",
                        accessibilityLabel: L("sidebar.aboutAccessibility"),
                        action: onOpenAbout
                    )
                }

                Spacer()

                StudioSidebarIconButton(
                    systemImage: "gearshape",
                    accessibilityLabel: L("sidebar.settingsAccessibility"),
                    action: { onSelect(.settings) }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, StudioTheme.Insets.sidebarOuterHorizontal)
        .padding(.vertical, StudioTheme.Insets.sidebarOuterVertical)
        .environment(\.locale, localization.locale)
    }

    private func sidebarNavigationButton(for section: StudioSection) -> some View {
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
                    .fill(section == currentSection ? StudioTheme.sidebarSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }
}

private struct StudioSidebarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary.opacity(0.9))
                .frame(width: StudioTheme.ControlSize.sidebarUtilityButton, height: StudioTheme.ControlSize.sidebarUtilityButton)
                .background(
                    Circle()
                        .fill(Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

struct StudioHeroHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                Text(title)
                    .font(.studioDisplay(StudioTheme.Typography.heroTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                if let badge {
                    StudioPill(title: badge)
                }
            }
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
    var isDisabled: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        StudioButtonChrome(
            variant: variant,
            isDisabled: isDisabled,
            isLoading: isLoading,
            minWidth: variant == .ghost ? nil : StudioTheme.ControlSize.buttonMinWidth,
            action: action
        ) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? .white : StudioTheme.textSecondary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                }
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            }
            .padding(.horizontal, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, variant == .ghost ? StudioTheme.Insets.none : StudioTheme.Insets.buttonVertical)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
        }
    }
}

struct StudioIconButton: View {
    let systemImage: String
    var variant: StudioButton.Variant = .ghost
    var isDisabled: Bool = false
    var isLoading: Bool = false
    var frame: CGFloat = 32
    let action: () -> Void

    var body: some View {
        StudioButtonChrome(
            variant: variant,
            isDisabled: isDisabled,
            isLoading: isLoading,
            minWidth: nil,
            action: action
        ) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? .white : StudioTheme.textSecondary)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: StudioTheme.Typography.iconRegular, weight: .medium))
                }
            }
            .frame(width: frame, height: frame)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
        }
    }
}

struct StudioPill: View {
    let title: String
    var tone: Color = StudioTheme.textSecondary
    var fill: Color = StudioTheme.surfaceMuted
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: StudioTheme.Typography.caption - 1, weight: .semibold))
            }
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
        }
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
    let badge: String?
    let accessory: Accessory

    init(title: String, subtitle: String, badge: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    if let badge {
                        StudioPill(title: badge)
                    }
                }
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

struct StudioTextInputCard<LabelTrailing: View>: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    @ViewBuilder var labelTrailing: () -> LabelTrailing

    init(label: String, placeholder: String, text: Binding<String>, secure: Bool = false, @ViewBuilder labelTrailing: @escaping () -> LabelTrailing = { EmptyView() }) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.labelTrailing = labelTrailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(alignment: .center) {
                Text(label)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                labelTrailing()
            }

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

struct StudioSuggestedTextInputCard<LabelTrailing: View>: View {
    let label: String
    let placeholder: String
    let suggestions: [String]
    @Binding var text: String
    @ViewBuilder var labelTrailing: () -> LabelTrailing

    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        suggestions: [String],
        @ViewBuilder labelTrailing: @escaping () -> LabelTrailing = { EmptyView() }
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.suggestions = suggestions
        self.labelTrailing = labelTrailing
    }

    private var normalizedSuggestions: [String] {
        var seen = Set<String>()
        return suggestions.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(alignment: .center) {
                Text(label)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                labelTrailing()
            }

            ZStack(alignment: .trailing) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.leading, StudioTheme.Insets.textFieldHorizontal)
                    .padding(.trailing, normalizedSuggestions.isEmpty ? StudioTheme.Insets.textFieldHorizontal : 58)
                    .padding(.vertical, StudioTheme.Insets.textFieldVertical)

                if !normalizedSuggestions.isEmpty {
                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        Rectangle()
                            .fill(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder))
                            .frame(width: 1, height: 18)

                        Menu {
                            ForEach(normalizedSuggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    text = suggestion
                                }
                            }
                        } label: {
                            Color.clear
                                .frame(width: 12, height: 12)
                        }
                        .menuStyle(.borderlessButton)
                        .help(L("common.selectSuggestedValue"))
                    }
                    .padding(.trailing, 12)
                }
            }
            .frame(minHeight: 46)
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
    let onCopyTranscript: (() -> Void)?
    let onDownloadAudio: (() -> Void)?
    let onDelete: (() -> Void)?
    let onRetry: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                Text(record.timestampText)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 108, alignment: .leading)

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                        Text(record.previewText)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge))
                            .foregroundStyle(record.hasFailure ? StudioTheme.danger : StudioTheme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if record.hasFailure {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                                .foregroundStyle(StudioTheme.danger)
                                .padding(.top, 3)
                                .help(record.failureMessage ?? L("workflow.processing.failed"))
                        }
                    }
                }

                Spacer(minLength: StudioTheme.Spacing.small)

                HStack(spacing: StudioTheme.Spacing.small) {
                    if let onCopyTranscript, record.hasTranscriptToCopy {
                        historyIconButton(systemImage: "doc.on.doc", helpText: L("history.action.copyTranscript"), action: onCopyTranscript)
                    }

                    Menu {
                        if let onRetry {
                            Button(L("common.retry"), systemImage: "arrow.clockwise", action: onRetry)
                                .disabled(!record.canRetry)
                        }
                        if let onDownloadAudio {
                            Button(L("history.action.downloadAudio"), systemImage: "arrow.down.circle", action: onDownloadAudio)
                                .disabled(record.audioFilePath == nil)
                        }
                        Divider()
                        if let onDelete {
                            Button(L("history.action.deleteTranscript"), systemImage: "trash", role: .destructive, action: onDelete)
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                            .fill(StudioTheme.surfaceMuted)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "ellipsis")
                                    .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                    historyDetailSection(title: L("history.detail.audioPath"), content: record.audioFilePath ?? L("history.detail.noAudioFile"))
                    historyDetailSection(title: L("history.detail.rawTranscript"), content: record.transcriptText, copyAction: record.hasTranscriptToCopy ? onCopyTranscript : nil)
                    historyDetailSection(title: L("history.detail.personaResult"), content: record.personaResultText)
                    historyDetailSection(title: L("history.detail.selectionOriginal"), content: record.selectionOriginalText)
                    historyDetailSection(title: L("history.detail.selectionEdited"), content: record.selectionEditedText)
                    historyDetailSection(title: L("history.detail.pipelineStats"), content: record.pipelineTimingDetails)
                    historyDetailSection(title: L("history.detail.error"), content: record.errorMessage, emphasize: true)
                }
                .padding(.top, StudioTheme.Spacing.xSmall)
            }
        }
        .padding(.horizontal, StudioTheme.Insets.historyRowHorizontal)
        .padding(.vertical, StudioTheme.Insets.historyRowVertical)
        .background(StudioTheme.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
        }
    }

    private func historyIconButton(systemImage: String, helpText: String, action: @escaping () -> Void) -> some View {
        StudioIconButton(systemImage: systemImage, action: action)
            .help(helpText)
    }

    @ViewBuilder
    private func historyDetailSection(
        title: String,
        content: String?,
        emphasize: Bool = false,
        copyAction: (() -> Void)? = nil
    ) -> some View {
        if let content, !content.isEmpty {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)

                    Spacer()

                    if let copyAction {
                        StudioIconButton(systemImage: "doc.on.doc", frame: 24, action: copyAction)
                            .help(L("history.action.copyTranscript"))
                    }
                }

                Text(content)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(emphasize ? StudioTheme.danger : StudioTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(StudioTheme.Insets.cardDense)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .fill(StudioTheme.surfaceMuted.opacity(0.72))
            )
        }
    }
}

struct StudioSegmentedPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                        .foregroundStyle(selection == option.value ? .white : StudioTheme.textPrimary)
                        .padding(.horizontal, StudioTheme.Insets.segmentedItemHorizontal)
                        .padding(.vertical, StudioTheme.Insets.segmentedItemVertical)
                        .background(
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedItem - 2, style: .continuous)
                                .fill(selection == option.value ? StudioTheme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(StudioTheme.Insets.segmentedControlVertical)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedControl, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.segmentedControlFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.segmentedControl, style: .continuous)
                .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
        )
    }
}

struct StudioMenuPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var width: CGFloat? = nil

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.label) {
                    selection = option.value
                }
            }
        } label: {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Text(selectedLabel)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, StudioTheme.Insets.buttonVertical)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .fill(StudioTheme.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
