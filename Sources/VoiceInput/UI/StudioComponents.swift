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
    let searchText: Binding<String>
    let searchPlaceholder: String
    let content: Content

    init(
        currentSection: StudioSection,
        onSelect: @escaping (StudioSection) -> Void,
        onOpenAbout: @escaping () -> Void,
        searchText: Binding<String>,
        searchPlaceholder: String,
        @ViewBuilder content: () -> Content
    ) {
        self.currentSection = currentSection
        self.onSelect = onSelect
        self.onOpenAbout = onOpenAbout
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.content = content()
    }

    var body: some View {
        ZStack {
            StudioTheme.windowBackground
                .ignoresSafeArea()

            HStack(spacing: StudioTheme.Spacing.none) {
                StudioSidebar(currentSection: currentSection, onSelect: onSelect, onOpenAbout: onOpenAbout)
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
    let onOpenAbout: () -> Void

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

            Button(action: onOpenAbout) {
                HStack {
                    Spacer()
                    Text("About")
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(StudioTheme.textSecondary.opacity(0.58))
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .accessibilityLabel("About VoiceInput")
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
                                .help(record.failureMessage ?? "Processing failed.")
                        }
                    }
                }

                Spacer(minLength: StudioTheme.Spacing.small)

                HStack(spacing: StudioTheme.Spacing.small) {
                    if let onCopyTranscript, record.hasTranscriptToCopy {
                        historyIconButton(systemImage: "doc.on.doc", helpText: "复制转写文本", action: onCopyTranscript)
                    }

                    Menu {
                        if let onRetry {
                            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                                .disabled(!record.canRetry)
                        }
                        if let onDownloadAudio {
                            Button("Download audio", systemImage: "arrow.down.circle", action: onDownloadAudio)
                                .disabled(record.audioFilePath == nil)
                        }
                        Divider()
                        if let onDelete {
                            Button("Delete transcript", systemImage: "trash", role: .destructive, action: onDelete)
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
                    historyDetailSection(title: "Audio Path", content: record.audioFilePath ?? "No audio file")
                    historyDetailSection(title: "模型原始转写", content: record.transcriptText, copyAction: record.hasTranscriptToCopy ? onCopyTranscript : nil)
                    historyDetailSection(title: "Persona 处理结果", content: record.personaResultText)
                    historyDetailSection(title: "选中文本", content: record.selectionOriginalText)
                    historyDetailSection(title: "选中文本修改结果", content: record.selectionEditedText)
                    historyDetailSection(title: "错误信息", content: record.errorMessage, emphasize: true)
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
                            .help("复制转写文本")
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
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
    }
}
