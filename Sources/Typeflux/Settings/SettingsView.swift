import AppKit
import SwiftUI

private enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L("vocabulary.filter.all")
        case .automatic:
            return L("vocabulary.filter.automatic")
        case .manual:
            return L("vocabulary.filter.manual")
        }
    }

    var source: VocabularySource? {
        switch self {
        case .all:
            return nil
        case .automatic:
            return .automatic
        case .manual:
            return .manual
        }
    }

    var iconName: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .automatic:
            return "sparkles"
        case .manual:
            return "hand.draw"
        }
    }
}

struct StudioView: View {
    private enum ShortcutRecordingTarget {
        case activation
        case ask
        case persona
    }

    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingTarget: ShortcutRecordingTarget?
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var isAddingVocabulary = false
    @State private var newVocabularyTerm = ""
    @State private var personaPendingDeletion: PersonaProfile?
    @State private var localSTTPendingDelete: LocalSTTModel? = nil
    @State private var localSTTPendingRedownload: LocalSTTModel? = nil
    @State private var llmActivationMissingAPIKeyProviderName: String?
    @State private var isMCPServerDialogPresented = false
    @State private var mcpServerPendingDeletion: MCPServerConfig? = nil
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        StudioShell(
            currentSection: viewModel.currentSection,
            onSelect: viewModel.navigate,
            onOpenAbout: { AboutWindowController.shared.show() },
            onSendFeedback: sendFeedbackEmail,
            searchText: $viewModel.searchQuery,
            searchPlaceholder: viewModel.currentSection.searchPlaceholder,
            agentEnabled: viewModel.agentFrameworkEnabled
        ) { viewportSize in
            let viewportHeight = viewportContentHeight(from: viewportSize)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.heroSection) {
                pageHeader

                if viewModel.currentSection == .models {
                    GeometryReader { proxy in
                        modelsPage(viewportHeight: proxy.size.height)
                    }
                } else {
                    currentPage
                }
            }
            .frame(
                height: viewModel.currentSection == .models ? viewportHeight : nil, alignment: .top
            )
            .id(viewModel.currentSection)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: viewModel.currentSection)
        }
        .onAppear {
            AppLocalization.shared.setLanguage(viewModel.appLanguage)
            viewModel.schedulePermissionRefresh()
        }
        .preferredColorScheme(viewModel.preferredColorScheme)
        .environment(\.locale, viewModel.locale)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            viewModel.schedulePermissionRefresh()
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, StudioTheme.Insets.toastHorizontal)
                    .padding(.vertical, StudioTheme.Insets.toastVertical)
                    .background(
                        Capsule()
                            .fill(StudioTheme.surface)
                    )
                    .overlay(
                        Capsule().stroke(
                            StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
                    )
                    .padding(.bottom, StudioTheme.Insets.toastBottom)
            }
        }
        .sheet(isPresented: $isAddingVocabulary) {
            vocabularyAddSheet
        }
        .confirmationDialog(
            L("settings.personas.deleteDialog.title"),
            isPresented: Binding(
                get: { personaPendingDeletion != nil },
                set: { if !$0 { personaPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("common.delete"), role: .destructive) {
                guard let personaPendingDeletion else { return }
                viewModel.deletePersona(id: personaPendingDeletion.id)
                self.personaPendingDeletion = nil
            }
            Button(L("common.cancel"), role: .cancel) {
                personaPendingDeletion = nil
            }
        } message: {
            if let personaPendingDeletion {
                Text(L("settings.personas.deleteDialog.message", personaPendingDeletion.name))
            }
        }
        .alert(
            L("settings.models.activationMissingAPIKey.title"),
            isPresented: Binding(
                get: { llmActivationMissingAPIKeyProviderName != nil },
                set: { if !$0 { llmActivationMissingAPIKeyProviderName = nil } }
            ),
            actions: {
                Button(L("common.ok"), role: .cancel) {
                    llmActivationMissingAPIKeyProviderName = nil
                }
            },
            message: {
                if let providerName = llmActivationMissingAPIKeyProviderName {
                    Text(L("settings.models.activationMissingAPIKey.message", providerName))
                }
            }
        )
        .sheet(isPresented: $isMCPServerDialogPresented) {
            mcpServerDialog
        }
        .confirmationDialog(
            L("agent.mcp.deleteDialog.title"),
            isPresented: Binding(
                get: { mcpServerPendingDeletion != nil },
                set: { if !$0 { mcpServerPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("common.delete"), role: .destructive) {
                guard let server = mcpServerPendingDeletion else { return }
                viewModel.removeMCPServer(id: server.id)
                mcpServerPendingDeletion = nil
            }
            Button(L("common.cancel"), role: .cancel) {
                mcpServerPendingDeletion = nil
            }
        } message: {
            if let server = mcpServerPendingDeletion {
                Text(L("agent.mcp.deleteDialog.message", server.name.isEmpty ? L("agent.mcp.untitled") : server.name))
            }
        }
    }

    private func sendFeedbackEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "mylxsw@aicode.cc"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Typeflux Feedback"),
            URLQueryItem(
                name: "body", value: "Hi,\n\nI want to share some feedback about Typeflux:\n"),
        ]

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private var pageHeader: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
            StudioHeroHeader(
                eyebrow: viewModel.currentSection.eyebrow,
                title: viewModel.currentSection.heading,
                subtitle: viewModel.currentSection.subheading,
                badge: viewModel.currentSection == .agent ? "Beta" : nil
            )

            if viewModel.currentSection == .vocabulary {
                Spacer()

                StudioButton(
                    title: L("vocabulary.action.newWord"), systemImage: "plus", variant: .primary
                ) {
                    newVocabularyTerm = ""
                    isAddingVocabulary = true
                }
            } else if viewModel.currentSection == .personas {
                Spacer()

                Button(action: viewModel.beginCreatingPersona) {
                    Image(systemName: "plus")
                        .foregroundStyle(.white)
                        .frame(
                            width: StudioTheme.ControlSize.personaAddButton,
                            height: StudioTheme.ControlSize.personaAddButton
                        )
                        .background(Circle().fill(StudioTheme.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(StudioInteractiveButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch viewModel.currentSection {
        case .home:
            homePage
        case .models:
            EmptyView()
        case .personas:
            personasPage
        case .vocabulary:
            vocabularyPage
        case .history:
            historyPage
        case .settings:
            settingsPage
        case .agent:
            agentPage
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            overviewPanel

            HStack {
                Text(L("home.recentTranscriptions"))
                    .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Button {
                    viewModel.navigate(to: .history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .studioTooltip(L("home.openHistory"), yOffset: 28)
            }

            sessionStream(
                records: Array(
                    viewModel.displayedHistory.prefix(StudioTheme.Count.homeRecentRecords)))
        }
    }

    private func modelsPage(viewportHeight: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ForEach(StudioModelDomain.allCases) { domain in
                    Button {
                        viewModel.setModelDomain(domain)
                    } label: {
                        Text(modelDomainTabTitle(for: domain))
                            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                            .foregroundStyle(
                                viewModel.modelDomain == domain
                                    ? StudioTheme.textPrimary : StudioTheme.textSecondary
                            )
                            .padding(.horizontal, StudioTheme.Insets.segmentedItemHorizontal)
                            .padding(.vertical, StudioTheme.Insets.segmentedItemVertical)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.segmentedItem,
                                    style: .continuous
                                )
                                .fill(
                                    viewModel.modelDomain == domain
                                        ? StudioTheme.surface : Color.clear)
                            )
                            .contentShape(
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.segmentedItem,
                                    style: .continuous))
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                }
            }
            .padding(.horizontal, StudioTheme.Insets.segmentedControlHorizontal)
            .padding(.vertical, StudioTheme.Insets.segmentedControlVertical)
            .background(
                RoundedRectangle(
                    cornerRadius: StudioTheme.CornerRadius.segmentedControl, style: .continuous
                )
                .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.segmentedControlFill))
            )
            .frame(minHeight: StudioTheme.Layout.modelTabsMinHeight, alignment: .leading)

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                            ForEach(modelProviderCards) { card in
                                modelProviderSelectionCard(card)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(
                        width: StudioTheme.Layout.modelProviderListWidth, height: proxy.size.height,
                        alignment: .leading
                    )
                    .frame(maxHeight: .infinity, alignment: .top)

                    focusedProviderConfigurationPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(height: viewportHeight, alignment: .top)
    }

    private func viewportContentHeight(from viewportSize: CGSize) -> CGFloat {
        max(
            viewportSize.height - StudioTheme.Layout.shellContentTopInset
                - StudioTheme.Layout.shellContentBottomInset,
            0
        )
    }

    private func modelDomainTabTitle(for domain: StudioModelDomain) -> String {
        switch domain {
        case .stt:
            return L("settings.models.domain.stt")
        case .llm:
            return L("settings.models.domain.llm")
        }
    }

    private var personasPage: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.section) {
            StudioCard {
                VStack(spacing: StudioTheme.Spacing.smallMedium) {
                    ForEach(viewModel.filteredPersonas) { persona in
                        Button {
                            viewModel.selectPersona(persona.id)
                        } label: {
                            HStack(spacing: StudioTheme.Spacing.medium) {
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.medium,
                                    style: .continuous
                                )
                                .fill(StudioTheme.accentSoft)
                                .frame(
                                    width: StudioTheme.ControlSize.personaAvatar,
                                    height: StudioTheme.ControlSize.personaAvatar
                                )
                                .overlay(
                                    Text(
                                        String(
                                            persona.name.prefix(StudioTheme.Count.personaInitials)
                                        ).uppercased()
                                    )
                                    .font(.studioBody(StudioTheme.Typography.body, weight: .bold))
                                    .foregroundStyle(StudioTheme.accent)
                                )
                                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                                    HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                                        Text(persona.name)
                                            .font(
                                                .studioBody(
                                                    StudioTheme.Typography.bodyLarge,
                                                    weight: .semibold)
                                            )
                                            .foregroundStyle(StudioTheme.textPrimary)
                                            .lineLimit(1)

                                        Spacer(minLength: StudioTheme.Spacing.small)

                                        if persona.isSystem {
                                            Text(L("settings.personas.tag.system"))
                                                .font(.studioBody(9, weight: .semibold))
                                                .foregroundStyle(StudioTheme.textTertiary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule()
                                                        .fill(StudioTheme.surfaceMuted)
                                                )
                                                .overlay(
                                                    Capsule()
                                                        .stroke(
                                                            StudioTheme.border.opacity(0.75),
                                                            lineWidth: StudioTheme.BorderWidth.thin)
                                                )
                                        }
                                    }
                                    Text(persona.prompt)
                                        .font(.studioBody(StudioTheme.Typography.caption))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .lineLimit(StudioTheme.LineLimit.personaPrompt)
                                }
                            }
                            .padding(StudioTheme.Insets.personaRow)
                            .padding(.trailing, 18)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.xxLarge,
                                    style: .continuous
                                )
                                .fill(
                                    viewModel.selectedPersonaID == persona.id
                                        ? StudioTheme.surfaceMuted : Color.clear)
                            )
                            .overlay(alignment: .trailing) {
                                Circle()
                                    .fill(
                                        persona.id.uuidString == viewModel.activePersonaID
                                            ? StudioTheme.accent : Color.clear
                                    )
                                    .frame(
                                        width: StudioTheme.ControlSize.personaStatusDot,
                                        height: StudioTheme.ControlSize.personaStatusDot
                                    )
                                    .padding(.trailing, StudioTheme.Insets.personaRow)
                            }
                            .contentShape(
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.xxLarge,
                                    style: .continuous))
                        }
                        .buttonStyle(StudioInteractiveButtonStyle())
                        .contextMenu {
                            if !persona.isSystem {
                                Button(L("common.delete"), role: .destructive) {
                                    viewModel.selectPersona(persona.id)
                                    personaPendingDeletion = persona
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: StudioTheme.Layout.personasListWidth)

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioTextInputCard(
                        label: L("settings.personas.name"),
                        placeholder: L("settings.personas.namePlaceholder"),
                        text: Binding(
                            get: { viewModel.personaDraftName },
                            set: { viewModel.personaDraftName = $0 }
                        )
                    )
                    .disabled(
                        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                    )
                    .opacity(
                        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                            ? 0.6 : 1)
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSectionTitle(title: L("settings.personas.prompt"))

                    TextEditor(
                        text: Binding(
                            get: { viewModel.personaDraftPrompt },
                            set: { viewModel.personaDraftPrompt = $0 }
                        )
                    )
                    .font(.studioMono(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .disabled(
                        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                    )
                    .frame(minHeight: StudioTheme.Layout.textEditorMinHeight)
                    .padding(StudioTheme.Insets.textEditor)
                    .background(
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                        )
                        .fill(StudioTheme.surfaceMuted)
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                        )
                        .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
                    )
                    .opacity(
                        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                            ? 0.6 : 1)
                }

                if !(viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft) {
                    HStack {
                        Spacer()
                        StudioButton(
                            title: L("common.cancel"), systemImage: nil, variant: .secondary
                        ) {
                            viewModel.cancelPersonaEditing()
                        }
                        StudioButton(
                            title: L("common.save"),
                            systemImage: nil,
                            variant: .primary,
                            isDisabled: !viewModel.canSavePersonaDraft
                                || !viewModel.hasPersonaDraftChanges
                        ) {
                            viewModel.savePersonaDraft()
                        }
                    }
                }
            }
        }
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("history.keep.title"),
                        subtitle: L("history.keep.subtitle")
                    ) {
                        StudioMenuPicker(
                            options: HistoryRetentionPolicy.allCases.map {
                                (label: $0.title, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.historyRetentionPolicy },
                                set: viewModel.setHistoryRetentionPolicy
                            ),
                            width: 140
                        )
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("history.privacy.title"),
                        subtitle: L("history.privacy.subtitle")
                    ) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(StudioTheme.success)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("history.export.title"),
                        subtitle: L("history.export.subtitle")
                    ) {
                        HStack(spacing: StudioTheme.Spacing.medium) {
                            StudioIconButton(
                                systemImage: "square.and.arrow.up",
                                variant: .primary
                            ) {
                                viewModel.exportHistory()
                            }
                            .studioTooltip(L("history.action.exportMarkdown"), yOffset: 34)
                            StudioIconButton(
                                systemImage: "trash",
                                variant: .ghost
                            ) {
                                viewModel.clearHistory()
                            }
                            .studioTooltip(L("common.clear"), yOffset: 34)
                        }
                    }
                }
            }

            groupedSessionStream(sections: viewModel.groupedHistory)
        }
    }

    private func groupedSessionStream(sections: [HistorySection]) -> some View {
        LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if sections.isEmpty {
                StudioCard(padding: StudioTheme.Insets.none) {
                    Text(L("history.empty"))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, StudioTheme.Insets.sessionEmptyVertical)
                }
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                        Text(section.id)
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, StudioTheme.Insets.historyRowHorizontal)

                        StudioCard(padding: StudioTheme.Insets.none) {
                            VStack(spacing: StudioTheme.Spacing.none) {
                                ForEach(section.records) { record in
                                    StudioHistoryRow(
                                        record: record,
                                        onCopyTranscript: {
                                            viewModel.copyTranscript(id: record.id)
                                        },
                                        onDownloadAudio: {
                                            viewModel.downloadAudio(id: record.id)
                                        },
                                        onDelete: {
                                            viewModel.deleteHistoryRecord(id: record.id)
                                        },
                                        onRetry: {
                                            viewModel.retryHistoryRecord(id: record.id)
                                        }
                                    )
                                    if record.id != section.records.last?.id {
                                        Divider().overlay(
                                            StudioTheme.border.opacity(
                                                StudioTheme.Opacity.listDivider))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if viewModel.isLoadingMoreHistory {
                HStack(spacing: StudioTheme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("history.loadingMore"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, StudioTheme.Spacing.medium)
            } else if viewModel.canLoadMoreHistory {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        viewModel.loadMoreHistoryIfNeeded()
                    }
            }
        }
    }

    private var vocabularyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioCard {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        ForEach(VocabularyFilter.allCases) { filter in
                            vocabularyFilterChip(filter)
                        }
                    }

                    Spacer()

                    HStack(spacing: StudioTheme.Spacing.small) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(StudioTheme.textTertiary)

                        TextField(L("vocabulary.search.placeholder"), text: $viewModel.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .frame(width: 220)
                    }
                    .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
                    .padding(.vertical, StudioTheme.Insets.textFieldVertical)
                    .background(
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous
                        )
                        .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous
                        )
                        .stroke(
                            StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                            lineWidth: StudioTheme.BorderWidth.thin)
                    )
                }

                if filteredVocabularyEntries.isEmpty {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        Text(L("vocabulary.empty.title"))
                            .font(
                                .studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold)
                            )
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(L("vocabulary.empty.subtitle"))
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                        StudioButton(
                            title: L("vocabulary.action.addFirst"), systemImage: "plus",
                            variant: .secondary
                        ) {
                            newVocabularyTerm = ""
                            isAddingVocabulary = true
                        }
                    }
                    .padding(.vertical, StudioTheme.Insets.historyEmptyVertical)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                            GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                        ],
                        alignment: .leading,
                        spacing: StudioTheme.Spacing.medium
                    ) {
                        ForEach(filteredVocabularyEntries) { entry in
                            vocabularyTermCard(entry)
                        }
                    }
                }
            }

        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSectionTitle(title: L("settings.general"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("settings.launchAtLogin.title"),
                        subtitle: L("settings.launchAtLogin.subtitle")
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.launchAtLogin },
                                set: viewModel.setLaunchAtLogin
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.appearance.title"),
                        subtitle: L("settings.appearance.subtitle")
                    ) {
                        StudioSegmentedPicker(
                            options: AppearanceMode.allCases.map {
                                (label: $0.displayName, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.appearanceMode },
                                set: viewModel.setAppearanceMode
                            )
                        )
                        .frame(width: StudioTheme.Layout.appearancePickerWidth)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.language.title"),
                        subtitle: L("settings.language.subtitle")
                    ) {
                        StudioMenuPicker(
                            options: AppLanguage.allCases.map {
                                (label: $0.displayName, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.appLanguage },
                                set: viewModel.setAppLanguage
                            ),
                            width: StudioTheme.Layout.appearancePickerWidth
                        )
                    }
                }
            }

            StudioSectionTitle(title: L("settings.activationHotkey"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                        shortcutConfigurationRow(
                            title: L("settings.shortcuts.activation.title"),
                            subtitle: L("settings.shortcuts.activation.subtitle"),
                            footnote: L("settings.shortcuts.activation.footnote"),
                            icon: "command",
                            badgeSymbol: "mic.fill",
                            binding: viewModel.activationHotkey,
                            isDefault: viewModel.activationHotkey.signature
                                == HotkeyBinding.defaultActivation.signature,
                            onStartRecording: {
                                recordingTarget = .activation
                                recorder.start { binding in
                                    viewModel.setActivationHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetActivationHotkey()
                            }
                        )

                        shortcutConfigurationRow(
                            title: L("settings.shortcuts.ask.title"),
                            subtitle: L("settings.shortcuts.ask.subtitle"),
                            footnote: L("settings.shortcuts.ask.footnote"),
                            icon: "questionmark.bubble.fill",
                            badgeSymbol: "text.quote",
                            binding: viewModel.askHotkey,
                            isDefault: viewModel.askHotkey.signature
                                == HotkeyBinding.defaultAsk.signature,
                            onStartRecording: {
                                recordingTarget = .ask
                                recorder.start { binding in
                                    viewModel.setAskHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetAskHotkey()
                            }
                        )

                        shortcutConfigurationRow(
                            title: L("settings.shortcuts.persona.title"),
                            subtitle: L("settings.shortcuts.persona.subtitle"),
                            footnote: L("settings.shortcuts.persona.footnote"),
                            icon: "person.crop.rectangle.stack.fill",
                            badgeSymbol: "person.crop.circle.badge.checkmark",
                            binding: viewModel.personaHotkey,
                            isDefault: viewModel.personaHotkey.signature
                                == HotkeyBinding.defaultPersona.signature,
                            onStartRecording: {
                                recordingTarget = .persona
                                recorder.start { binding in
                                    viewModel.setPersonaHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetPersonaHotkey()
                            }
                        )
                    }

                    if recorder.isRecording {
                        recordingShortcutBanner
                    }
                }
            }

            StudioSectionTitle(title: L("settings.identity"))

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                            )
                            .fill(StudioTheme.accentSoft)
                            .frame(width: 46, height: 46)
                            .overlay(
                                Image(systemName: "person.crop.rectangle.stack.fill")
                                    .foregroundStyle(StudioTheme.accent)
                            )

                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                                Text(L("settings.personaDefault.title"))
                                    .font(
                                        .studioDisplay(
                                            StudioTheme.Typography.cardTitle, weight: .semibold)
                                    )
                                    .foregroundStyle(StudioTheme.textPrimary)
                                Text(L("settings.personaDefault.subtitle"))
                                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }

                            Spacer()

                            if let selectedID = viewModel.defaultPersonaSelectionID,
                                let persona = viewModel.personas.first(where: {
                                    $0.id == selectedID
                                })
                            {
                                StudioPill(title: persona.name)
                            } else {
                                StudioPill(
                                    title: L("persona.none.title"), systemImage: "person.slash")
                            }
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                            ],
                            alignment: .leading,
                            spacing: StudioTheme.Spacing.medium
                        ) {
                            personaSelectionCard(
                                title: L("persona.none.title"),
                                subtitle: L("persona.none.subtitle"),
                                initials: "",
                                systemImage: "person.slash.fill",
                                isSelected: viewModel.defaultPersonaSelectionID == nil
                            ) {
                                viewModel.setDefaultPersonaSelection(nil)
                            }

                            ForEach(viewModel.personas) { persona in
                                personaSelectionCard(
                                    title: persona.name,
                                    subtitle: persona.prompt,
                                    initials: String(persona.name.prefix(2)).uppercased(),
                                    isSelected: viewModel.defaultPersonaSelectionID == persona.id
                                ) {
                                    viewModel.setDefaultPersonaSelection(persona.id)
                                }
                            }
                        }

                        HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                            Text(
                                viewModel.personaRewriteEnabled
                                    ? L("settings.personaDefault.enabled")
                                    : L("settings.personaDefault.disabled")
                            )
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)

                            Spacer()

                            StudioButton(
                                title: L("settings.personaDefault.openPersonas"), systemImage: nil,
                                variant: .secondary
                            ) {
                                viewModel.navigate(to: .personas)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            StudioSectionTitle(title: L("settings.audio"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("settings.microphone.title"),
                        subtitle: L("settings.microphone.subtitle")
                    ) {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            StudioMenuPicker(
                                options: [
                                    (
                                        label: L("settings.microphone.automatic"),
                                        value: AudioDeviceManager.automaticDeviceID
                                    )
                                ]
                                    + viewModel.availableMicrophones.map {
                                        (label: $0.name, value: $0.id)
                                    },
                                selection: Binding(
                                    get: { viewModel.preferredMicrophoneID },
                                    set: viewModel.setPreferredMicrophoneID
                                ),
                                width: 260
                            )

                            StudioButton(
                                title: L("common.refresh"), systemImage: "arrow.clockwise",
                                variant: .secondary
                            ) {
                                viewModel.refreshAvailableMicrophones()
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.mute.title"),
                        subtitle: L("settings.mute.subtitle")
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.muteSystemOutputDuringRecording },
                                set: viewModel.setMuteSystemOutputDuringRecording
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            StudioSectionTitle(title: L("settings.permissions"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("settings.permissionStatus.title"),
                        subtitle: L("settings.permissionStatus.subtitle")
                    ) {
                        StudioButton(
                            title: viewModel.isRefreshingPermissions
                                ? L("common.refreshing") : L("common.refresh"),
                            systemImage: "arrow.clockwise",
                            variant: .secondary,
                            isLoading: viewModel.isRefreshingPermissions
                        ) {
                            viewModel.refreshPermissionRowsWithFeedback()
                        }
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                        ForEach(viewModel.permissionRows) { permission in
                            permissionRow(permission)

                            if permission.id != viewModel.permissionRows.last?.id {
                                Divider().overlay(
                                    StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                            }
                        }
                    }
                }
            }

            StudioSectionTitle(title: L("settings.advanced"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("settings.advanced.soundEffects.title"),
                        subtitle: L("settings.advanced.soundEffects.subtitle")
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.soundEffectsEnabled },
                                set: viewModel.setSoundEffectsEnabled
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.advanced.personaHotkeyApply.title"),
                        subtitle: L("settings.advanced.personaHotkeyApply.subtitle"),
                        badge: "Beta"
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.personaHotkeyAppliesToSelection },
                                set: viewModel.setPersonaHotkeyAppliesToSelection
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.advanced.autoVocabulary.title"),
                        subtitle: L("settings.advanced.autoVocabulary.subtitle")
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.automaticVocabularyCollectionEnabled },
                                set: viewModel.setAutomaticVocabularyCollectionEnabled
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.models.appleFallback"),
                        subtitle: L("settings.models.appleFallback.detail")
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.appleSpeechFallback },
                                set: viewModel.setAppleSpeechFallback
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.advanced.agentFramework.title"),
                        subtitle: L("settings.advanced.agentFramework.subtitle"),
                        badge: "Beta"
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.agentFrameworkEnabled },
                                set: viewModel.setAgentFrameworkEnabled
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: - Agent Page

    private var agentPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSectionTitle(title: L("agent.section.general"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("agent.general.enabled.title"),
                        subtitle: L("agent.general.enabled.subtitle")
                    ) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.agentEnabled },
                            set: viewModel.setAgentEnabled
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            StudioSectionTitle(title: L("agent.section.mcpServers"))

            if viewModel.mcpServers.isEmpty {
                StudioCard {
                    VStack(spacing: StudioTheme.Spacing.medium) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text(L("agent.mcp.empty"))
                            .font(.studioBody(StudioTheme.Typography.body, weight: .regular))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StudioTheme.Spacing.large)
                }
            } else {
                ForEach(viewModel.mcpServers) { server in
                    mcpServerListCard(server)
                }
            }

            StudioButton(
                title: L("agent.mcp.addServer"),
                systemImage: "plus.circle.fill",
                variant: .secondary
            ) {
                viewModel.beginAddMCPServer()
                isMCPServerDialogPresented = true
            }
        }
    }

    private func mcpServerListCard(_ server: MCPServerConfig) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            Text(server.name.isEmpty ? L("agent.mcp.untitled") : server.name)
                                .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            StudioPill(title: mcpTransportLabel(for: server))
                        }
                        Text(mcpTransportDetail(for: server))
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .regular))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    StudioButton(
                        title: viewModel.isTestingMCPServer(server.id)
                            ? L("agent.mcp.testing") : L("agent.mcp.testConnection"),
                        systemImage: viewModel.isTestingMCPServer(server.id) ? nil : "network",
                        variant: .secondary,
                        isDisabled: viewModel.isTestingMCPServer(server.id),
                        isLoading: viewModel.isTestingMCPServer(server.id)
                    ) {
                        viewModel.testMCPConnection(for: server)
                    }

                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { viewModel.updateMCPServerEnabled(id: server.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                if viewModel.shouldShowMCPConnectionTestResult(for: server.id) {
                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                    mcpConnectionTestResultView
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.beginEditMCPServer(server)
            isMCPServerDialogPresented = true
        }
        .contextMenu {
            Button(L("agent.mcp.edit")) {
                viewModel.beginEditMCPServer(server)
                isMCPServerDialogPresented = true
            }
            Divider()
            Button(L("common.delete"), role: .destructive) {
                mcpServerPendingDeletion = server
            }
        }
    }

    private var mcpServerDialog: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            Text(viewModel.mcpDraftEditingServerID == nil
                 ? L("agent.mcp.dialog.addTitle")
                 : L("agent.mcp.dialog.editTitle"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(L("agent.mcp.dialog.subtitle"))
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)

            StudioCard(padding: StudioTheme.Insets.cardDense) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioTextInputCard(
                        label: L("agent.mcp.name"),
                        placeholder: L("agent.mcp.namePlaceholder"),
                        text: $viewModel.mcpDraftName
                    )

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        Text(L("agent.mcp.transportType"))
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)

                        StudioSegmentedPicker(
                            options: [
                                (label: "STDIO", value: MCPTransportType.stdio),
                                (label: "HTTP/SSE", value: MCPTransportType.http)
                            ],
                            selection: $viewModel.mcpDraftTransportType
                        )
                    }

                    if viewModel.mcpDraftTransportType == .stdio {
                        StudioTextInputCard(
                            label: L("agent.mcp.stdio.command"),
                            placeholder: "/usr/local/bin/my-mcp-server",
                            text: $viewModel.mcpDraftStdioCommand
                        )
                        StudioTextInputCard(
                            label: L("agent.mcp.stdio.args"),
                            placeholder: "--port 3000 --verbose",
                            text: $viewModel.mcpDraftStdioArgs
                        )
                        mcpKeyValueEditor(
                            label: L("agent.mcp.stdio.env"),
                            hint: L("agent.mcp.stdio.envHint"),
                            text: $viewModel.mcpDraftStdioEnv
                        )
                    } else {
                        StudioTextInputCard(
                            label: L("agent.mcp.http.url"),
                            placeholder: "https://mcp.example.com/sse",
                            text: $viewModel.mcpDraftHTTPURL
                        )
                        mcpKeyValueEditor(
                            label: L("agent.mcp.http.headers"),
                            hint: L("agent.mcp.http.headersHint"),
                            text: $viewModel.mcpDraftHTTPHeaders
                        )
                    }
                }
            }

            StudioCard(padding: StudioTheme.Insets.cardDense) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("agent.mcp.enabled.title"),
                        subtitle: L("agent.mcp.enabled.subtitle")
                    ) {
                        Toggle("", isOn: $viewModel.mcpDraftEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("agent.mcp.autoConnect.title"),
                        subtitle: L("agent.mcp.autoConnect.subtitle")
                    ) {
                        Toggle("", isOn: $viewModel.mcpDraftAutoConnect)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            mcpConnectionTestResultView

            HStack {
                StudioButton(title: L("common.cancel"), systemImage: nil, variant: .secondary) {
                    isMCPServerDialogPresented = false
                }

                Spacer()

                StudioButton(
                    title: viewModel.mcpConnectionTestState == .testing
                        ? L("agent.mcp.testing") : L("agent.mcp.testConnection"),
                    systemImage: viewModel.mcpConnectionTestState == .testing ? nil : "network",
                    variant: .secondary,
                    isDisabled: viewModel.mcpConnectionTestState == .testing,
                    isLoading: viewModel.mcpConnectionTestState == .testing
                ) {
                    viewModel.testMCPDraftConnection()
                }
                StudioButton(
                    title: L("common.save"),
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: !viewModel.canSaveMCPDraft
                ) {
                    viewModel.saveMCPDraft()
                    isMCPServerDialogPresented = false
                }
            }
        }
        .padding(StudioTheme.Insets.cardDefault)
        .frame(width: 520)
    }

    private func mcpKeyValueEditor(label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            Text(label)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(hint)
                        .font(.studioBody(StudioTheme.Typography.bodyLarge))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal + 4)
                        .padding(.vertical, StudioTheme.Insets.textFieldVertical + 2)
                        .allowsHitTesting(false)
                }

                TextEditor(text: text)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 100)
                    .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
                    .padding(.vertical, StudioTheme.Insets.textFieldVertical)
            }
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
            )
        }
    }

    @ViewBuilder
    private var mcpConnectionTestResultView: some View {
        switch viewModel.mcpConnectionTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ProgressView().controlSize(.small)
                Text(L("agent.mcp.testing"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        case .success(let tools):
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.success)
                    Text(L("agent.mcp.testSuccess", tools.count))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                if !tools.isEmpty {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                        ForEach(tools) { tool in
                            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .frame(width: 14, alignment: .center)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name)
                                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                    if !tool.description.isEmpty {
                                        Text(tool.description)
                                            .font(.studioBody(StudioTheme.Typography.caption, weight: .regular))
                                            .foregroundStyle(StudioTheme.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(StudioTheme.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                            .fill(StudioTheme.surfaceMuted)
                    )
                }
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.danger)
                Text(message)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mcpTransportLabel(for server: MCPServerConfig) -> String {
        switch server.transport {
        case .stdio: return "STDIO"
        case .http: return "HTTP/SSE"
        }
    }

    private func mcpTransportDetail(for server: MCPServerConfig) -> String {
        switch server.transport {
        case .stdio(let config): return config.command
        case .http(let config): return config.url
        }
    }

    private func shortcutConfigurationRow(
        title: String,
        subtitle: String,
        footnote: String,
        icon: String,
        badgeSymbol: String,
        binding: HotkeyBinding,
        isDefault: Bool,
        onStartRecording: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [StudioTheme.accentSoft, StudioTheme.surfaceMuted],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(title)
                    .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(footnote)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)

            Spacer(minLength: StudioTheme.Spacing.large)

            shortcutPill(binding, accentSymbol: badgeSymbol)
                .frame(minWidth: 170, alignment: .leading)

            shortcutActionButtons(
                isDefault: isDefault,
                onStart: onStartRecording,
                onReset: onReset
            )
        }
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private var recordingShortcutBanner: some View {
        HStack(spacing: StudioTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(StudioTheme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "keyboard")
                        .foregroundStyle(StudioTheme.accent)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(L("settings.shortcuts.recording"))
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(recordingBannerDescription)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            Spacer()
        }
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.accentSoft.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.accent.opacity(0.28), lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private func shortcutKeycap(_ title: String) -> some View {
        Text(title)
            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .fill(StudioTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .stroke(
                        StudioTheme.border.opacity(0.75), lineWidth: StudioTheme.BorderWidth.thin)
            )
    }

    private var recordingBannerDescription: String {
        switch recordingTarget {
        case .activation:
            return L("settings.shortcuts.recordingActivation")
        case .ask:
            return L("settings.shortcuts.recordingAsk")
        case .persona:
            return L("settings.shortcuts.recordingPersona")
        case nil:
            return L("settings.shortcuts.recordingGeneric")
        }
    }

    private func shortcutActionButtons(
        isDefault: Bool,
        onStart: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            StudioButton(
                title: recorder.isRecording
                    ? L("settings.shortcuts.stopRecording") : L("settings.shortcuts.record"),
                systemImage: recorder.isRecording ? "stop.circle.fill" : "keyboard",
                variant: recorder.isRecording ? .secondary : .primary
            ) {
                if recorder.isRecording {
                    recorder.stop()
                    recordingTarget = nil
                } else {
                    onStart()
                }
            }

            StudioButton(
                title: L("common.reset"), systemImage: "arrow.counterclockwise",
                variant: .secondary, isDisabled: isDefault
            ) {
                onReset()
            }
        }
    }

    private func shortcutPill(_ binding: HotkeyBinding, accentSymbol: String) -> some View {
        HStack(spacing: StudioTheme.Spacing.xxxSmall) {
            ForEach(HotkeyFormat.components(binding), id: \.self) { key in
                shortcutKeycap(key)
            }
        }
    }

    private func personaSelectionCard(
        title: String,
        subtitle: String,
        initials: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                    )
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Group {
                            if let systemImage {
                                Image(systemName: systemImage)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(
                                        isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                            } else {
                                Text(initials)
                                    .font(
                                        .studioBody(StudioTheme.Typography.caption, weight: .bold)
                                    )
                                    .foregroundStyle(
                                        isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                            }
                        }
                    )

                    Spacer()

                    Circle()
                        .stroke(
                            isSelected ? StudioTheme.accent : StudioTheme.border,
                            lineWidth: StudioTheme.BorderWidth.emphasis
                        )
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .fill(isSelected ? StudioTheme.accent : Color.clear)
                                .frame(width: 8, height: 8)
                        )
                }

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(StudioTheme.Insets.cardCompact)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(
                        isSelected
                            ? StudioTheme.accentSoft.opacity(0.75)
                            : StudioTheme.surfaceMuted.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isSelected
                            ? StudioTheme.accent.opacity(0.45)
                            : StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: isSelected
                            ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func permissionRow(_ permission: StudioPermissionRowModel) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                HStack(spacing: StudioTheme.Spacing.small) {
                    Image(
                        systemName: permission.isGranted
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(
                        permission.isGranted ? StudioTheme.success : StudioTheme.warning)

                    Text(permission.title)
                        .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    StudioPill(
                        title: permission.badgeText,
                        tone: permission.isGranted ? StudioTheme.success : StudioTheme.warning,
                        fill: (permission.isGranted ? StudioTheme.success : StudioTheme.warning)
                            .opacity(0.12)
                    )
                }

                Text(permission.summary)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge))
                    .foregroundStyle(StudioTheme.textSecondary)

                Text(permission.detail)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
            }

            Spacer(minLength: StudioTheme.Spacing.pageGroup)

            StudioButton(
                title: permission.actionTitle,
                systemImage: permission.isGranted ? "arrow.up.right.square" : "lock.open.display",
                variant: permission.isGranted ? .secondary : .primary
            ) {
                viewModel.requestPermission(permission.id)
            }
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
    }

    private var filteredVocabularyEntries: [VocabularyEntry] {
        let entries = viewModel.filteredVocabularyEntries
        guard let source = vocabularyFilter.source else { return entries }
        return entries.filter { $0.source == source }
    }

    private func vocabularyFilterChip(_ filter: VocabularyFilter) -> some View {
        Button {
            vocabularyFilter = filter
        } label: {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: filter.iconName)
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                Text(filter.title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                Text("\(vocabularyCount(for: filter))")
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                    .foregroundStyle(
                        vocabularyFilter == filter
                            ? StudioTheme.textPrimary : StudioTheme.textTertiary)
            }
            .foregroundStyle(
                vocabularyFilter == filter ? StudioTheme.textPrimary : StudioTheme.textSecondary
            )
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical + 2)
            .background(
                Capsule()
                    .fill(
                        vocabularyFilter == filter
                            ? StudioTheme.surface : StudioTheme.surfaceMuted.opacity(0.82))
            )
            .overlay(
                Capsule()
                    .stroke(
                        StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func vocabularyTermCard(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: entry.source == .automatic ? "sparkles" : "plus.circle.fill")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                .foregroundStyle(
                    entry.source == .automatic ? StudioTheme.warning : StudioTheme.accent)

            Text(entry.term)
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            Button {
                viewModel.removeVocabularyEntry(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .bold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(StudioTheme.surfaceMuted.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, StudioTheme.Insets.cardCompact)
        .padding(.vertical, StudioTheme.Insets.buttonVertical)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin)
        )
    }

    private var vocabularyAddSheet: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            Text(L("vocabulary.sheet.title"))
                .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(L("vocabulary.sheet.subtitle"))
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)

            TextField(L("vocabulary.sheet.placeholder"), text: $newVocabularyTerm)
                .textFieldStyle(.plain)
                .font(.studioBody(StudioTheme.Typography.bodyLarge))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, StudioTheme.Insets.textFieldHorizontal)
                .padding(.vertical, StudioTheme.Insets.textFieldVertical)
                .background(
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous
                    )
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous
                    )
                    .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
                )
                .onSubmit {
                    submitVocabularyTerm()
                }

            HStack {
                Spacer()
                StudioButton(title: L("common.cancel"), systemImage: nil, variant: .secondary) {
                    isAddingVocabulary = false
                }
                StudioButton(
                    title: L("vocabulary.action.addWord"),
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                ) {
                    submitVocabularyTerm()
                }
            }
        }
        .padding(32)
        .frame(width: 520)
    }

    private func submitVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        viewModel.addVocabularyTerm(term)
        newVocabularyTerm = ""
        isAddingVocabulary = false
    }

    private func vocabularyCount(for filter: VocabularyFilter) -> Int {
        guard let source = filter.source else { return viewModel.vocabularyEntries.count }
        return viewModel.vocabularyEntries.filter { $0.source == source }.count
    }

    private func uniqueSuggestions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private var whisperEndpointSuggestions: [String] {
        OpenAIAudioModelCatalog.whisperEndpoints
    }

    private var whisperModelSuggestions: [String] {
        OpenAIAudioModelCatalog.whisperModels
    }

    private func llmEndpointSuggestions(for provider: LLMRemoteProvider?) -> [String] {
        guard let provider else {
            return uniqueSuggestions([viewModel.llmBaseURL])
        }

        return uniqueSuggestions(
            [viewModel.llmBaseURL, provider.defaultBaseURL] + provider.endpointPresets.map(\.url)
        )
    }

    private var llmModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.llmModel,
            "gpt-4o-mini",
            "gpt-4.1-mini",
            "gpt-4.1",
        ])
    }

    private var focusedLLMRemoteProvider: LLMRemoteProvider? {
        LLMRemoteProvider.from(providerID: viewModel.focusedModelProvider)
    }

    private var activeLLMRemoteProvider: LLMRemoteProvider {
        viewModel.llmRemoteProvider
    }

    private var remoteLLMModelSuggestions: [String] {
        guard let provider = focusedLLMRemoteProvider else { return llmModelSuggestions }
        return uniqueSuggestions([viewModel.llmModel] + provider.suggestedModels)
    }

    private var ollamaEndpointSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaBaseURL,
            "http://127.0.0.1:11434",
            "http://localhost:11434",
        ])
    }

    private var ollamaModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaModel,
            "qwen2.5:7b",
            "llama3.2:3b",
            "gemma3:4b",
        ])
    }

    private var multimodalEndpointSuggestions: [String] {
        OpenAIAudioModelCatalog.multimodalEndpoints
    }

    private var multimodalModelSuggestions: [String] {
        OpenAIAudioModelCatalog.multimodalModels
    }

    @ViewBuilder
    private var llmRemoteProviderForm: some View {
        if let provider = focusedLLMRemoteProvider {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                if provider == .freeModel {
                    if FreeLLMModelRegistry.suggestedModelNames.isEmpty {
                        Text(L("settings.models.freeModel.noSources"))
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textTertiary)
                    } else {
                        StudioMenuPicker(
                            options: FreeLLMModelRegistry.suggestedModelNames.map { ($0, $0) },
                            selection: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                            width: 320
                        )
                    }

                    Text(L("settings.models.freeModel.hint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)

                    if !FreeLLMModelRegistry.sources.isEmpty {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(L("settings.models.freeModel.availableSources"))
                                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                .foregroundStyle(StudioTheme.textSecondary)

                            ForEach(FreeLLMModelRegistry.sourceSummaryLines(), id: \.self) { line in
                                Text(line)
                                    .font(.studioMono(StudioTheme.Typography.caption))
                                    .foregroundStyle(StudioTheme.textTertiary)
                            }
                        }
                    }
                } else {
                    StudioTextInputCard(
                        label: L("common.apiKey"),
                        placeholder: provider == .gemini ? "AIza..." : "sk-...",
                        text: Binding(get: { viewModel.llmAPIKey }, set: viewModel.setLLMAPIKey),
                        secure: true
                    )

                    StudioSuggestedTextInputCard(
                        label: L("settings.models.apiEndpoint"),
                        placeholder: provider.defaultBaseURL.isEmpty
                            ? "https://api.openai.com/v1" : provider.defaultBaseURL,
                        text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                        suggestions: llmEndpointSuggestions(for: provider)
                    )

                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: provider.defaultModel,
                        text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                        suggestions: remoteLLMModelSuggestions
                    )

                    Text(L("settings.models.llm.providerEndpointHint", provider.displayName))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
    }

    private var parameterCard: some View {
        StudioCard {
            StudioSectionTitle(title: L("settings.models.configuration"))
            if viewModel.modelDomain == .stt {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.endpoint"),
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: Binding(
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL),
                    suggestions: whisperEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.model"),
                    placeholder: OpenAIAudioModelCatalog.whisperModels[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions
                )
            } else {
                if viewModel.llmProvider == .ollama {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.ollama.baseURL"),
                        placeholder: "http://127.0.0.1:11434",
                        text: Binding(
                            get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL),
                        suggestions: ollamaEndpointSuggestions
                    )
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.localModel"),
                        placeholder: "qwen2.5:7b",
                        text: Binding(
                            get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel),
                        suggestions: ollamaModelSuggestions
                    )
                    Toggle(
                        L("settings.models.ollama.autoSetup"),
                        isOn: Binding(
                            get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup)
                    )
                    .toggleStyle(.switch)
                } else {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.remote.baseURL"),
                        placeholder: "https://api.openai.com/v1",
                        text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                        suggestions: llmEndpointSuggestions(for: focusedLLMRemoteProvider)
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: "gpt-4o-mini",
                        text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                        suggestions: llmModelSuggestions
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(get: { viewModel.llmAPIKey }, set: viewModel.setLLMAPIKey),
                        secure: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionCard: some View {
        StudioCard {
            StudioSectionTitle(title: L("settings.models.activation"))
            Text(L("settings.models.customArchitecture.title"))
                .font(.studioDisplay(StudioTheme.Typography.settingTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("settings.models.customArchitecture.subtitle"))
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)

            Spacer(minLength: StudioTheme.Spacing.smallMedium)

            HStack {
                StudioPill(title: "CoreML")
                StudioPill(title: "ONNX")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.actionCardMinHeight)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudioTheme.accentSoft,
                            StudioTheme.Colors.actionCardWarm,
                            StudioTheme.Colors.actionCardCool,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
    }

    private func historyTable(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            VStack(spacing: StudioTheme.Spacing.none) {
                HStack {
                    Text(L("history.table.timestamp"))
                        .frame(
                            width: StudioTheme.Layout.historyTimestampColumnWidth,
                            alignment: .leading)
                    Text(L("history.table.sourceFile"))
                        .frame(
                            width: StudioTheme.Layout.historySourceColumnWidth, alignment: .leading)
                    Text(L("history.table.recognizedText"))
                    Spacer()
                }
                .font(.studioBody(StudioTheme.Typography.sidebarEyebrow, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, StudioTheme.Insets.historyHeaderHorizontal)
                .padding(.top, StudioTheme.Insets.historyHeaderTop)
                .padding(.bottom, StudioTheme.Insets.historyHeaderBottom)

                Divider().overlay(StudioTheme.border)

                if records.isEmpty {
                    Text(L("history.empty"))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, StudioTheme.Insets.historyEmptyVertical)
                } else {
                    ForEach(records) { record in
                        StudioHistoryRow(
                            record: record,
                            onCopyTranscript: {
                                viewModel.copyTranscript(id: record.id)
                            },
                            onDownloadAudio: {
                                viewModel.downloadAudio(id: record.id)
                            },
                            onDelete: {
                                viewModel.deleteHistoryRecord(id: record.id)
                            },
                            onRetry: {
                                viewModel.retryHistoryRecord(id: record.id)
                            }
                        )
                        if record.id != records.last?.id {
                            Divider().overlay(StudioTheme.border)
                        }
                    }
                }
            }
        }
    }

    private var overviewPanel: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
            StudioCard(padding: StudioTheme.Insets.cardDense) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                            HStack(spacing: StudioTheme.Spacing.small) {
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous
                                )
                                .fill(StudioTheme.surfaceMuted)
                                .frame(
                                    width: StudioTheme.ControlSize.overviewBadge,
                                    height: StudioTheme.ControlSize.overviewBadge
                                )
                                .overlay(
                                    Image(systemName: "waveform.and.magnifyingglass")
                                        .font(
                                            .system(
                                                size: StudioTheme.Typography.iconSmall,
                                                weight: .semibold)
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary)
                                )
                                Text(L("home.activity.title"))
                                    .font(
                                        .studioBody(StudioTheme.Typography.bodySmall, weight: .semibold)
                                    )
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }

                            Text("\(viewModel.statsCompletionRate)%")
                                .font(
                                    .studioDisplay(StudioTheme.Typography.displayLarge, weight: .bold)
                                )
                                .foregroundStyle(StudioTheme.textPrimary)

                            Text(L("home.activity.completionRate"))
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }

                        Spacer(minLength: StudioTheme.Spacing.medium)

                        Circle()
                            .stroke(
                                StudioTheme.surfaceMuted,
                                lineWidth: StudioTheme.BorderWidth.overviewDonut
                            )
                            .frame(
                                width: StudioTheme.Layout.overviewDonutSize,
                                height: StudioTheme.Layout.overviewDonutSize
                            )
                            .overlay(
                                Circle()
                                    .trim(from: 0, to: CGFloat(viewModel.statsCompletionRate) / 100)
                                    .stroke(
                                        StudioTheme.accent.opacity(
                                            StudioTheme.Opacity.overviewProgress),
                                        style: StrokeStyle(
                                            lineWidth: StudioTheme.BorderWidth.overviewDonut,
                                            lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(StudioTheme.Angles.overviewProgressStart))
                            )
                            .padding(.trailing, StudioTheme.Spacing.smallMedium)
                            .padding(.vertical, StudioTheme.Spacing.smallMedium)
                    }

                    Spacer(minLength: StudioTheme.Spacing.smallMedium)

                    Text(L("home.activity.privacy"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.overviewPrimaryMinHeight)
            .background(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.overviewActivityFill))
            .clipShape(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))

            GeometryReader { proxy in
                let spacing = StudioTheme.Spacing.medium
                let cardWidth = max((proxy.size.width - spacing) / 2, 0)
                let cardHeight = max((proxy.size.height - spacing) / 2, 0)

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        homeMiniMetric(
                            icon: "clock",
                            value: "\(viewModel.transcriptionMinutesText) min",
                            title: L("home.metric.totalDictation"),
                            size: CGSize(width: cardWidth, height: cardHeight)
                        )
                        homeMiniMetric(
                            icon: "mic",
                            value: "\(viewModel.statsTotalCharacters)",
                            title: L("home.metric.charactersDictated"),
                            size: CGSize(width: cardWidth, height: cardHeight)
                        )
                    }

                    HStack(spacing: spacing) {
                        homeMiniMetric(
                            icon: "hourglass",
                            value: "\(viewModel.statsSavedMinutes) min",
                            title: L("home.metric.timeSaved"),
                            size: CGSize(width: cardWidth, height: cardHeight)
                        )
                        homeMiniMetric(
                            icon: "bolt",
                            value: viewModel.statsAveragePaceWPM > 0
                                ? "\(viewModel.statsAveragePaceWPM) wpm" : "--",
                            title: L("home.metric.averagePace"),
                            size: CGSize(width: cardWidth, height: cardHeight)
                        )
                    }
                }
            }
            .frame(
                minWidth: StudioTheme.Layout.overviewSideMetricsWidth,
                maxWidth: .infinity,
                minHeight: StudioTheme.Layout.overviewPrimaryMinHeight,
                maxHeight: StudioTheme.Layout.overviewPrimaryMinHeight,
                alignment: .top
            )
        }
    }

    private func homeMiniMetric(icon: String, value: String, title: String, size: CGSize)
        -> some View
    {
        StudioCard(padding: StudioTheme.Insets.cardCompact) {
            VStack(alignment: .center, spacing: StudioTheme.Spacing.smallMedium) {
                RoundedRectangle(
                    cornerRadius: StudioTheme.CornerRadius.miniMetricIcon, style: .continuous
                )
                .fill(StudioTheme.surfaceMuted)
                .frame(
                    width: StudioTheme.ControlSize.overviewMiniIcon,
                    height: StudioTheme.ControlSize.overviewMiniIcon
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                )

                Text(value)
                    .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }

    private func sectionHeader(
        title: String,
        secondaryButtonTitle: String,
        secondaryAction: @escaping () -> Void,
        primaryButtonTitle: String,
        primaryAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            StudioButton(
                title: secondaryButtonTitle, systemImage: nil, variant: .secondary,
                action: secondaryAction)
            StudioButton(
                title: primaryButtonTitle, systemImage: nil, variant: .primary,
                action: primaryAction)
        }
    }

    private func sessionStream(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            if records.isEmpty {
                Text(L("history.empty"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, StudioTheme.Insets.sessionEmptyVertical)
            } else {
                VStack(spacing: StudioTheme.Spacing.none) {
                    ForEach(records) { record in
                        StudioHistoryRow(
                            record: record,
                            onCopyTranscript: {
                                viewModel.copyTranscript(id: record.id)
                            },
                            onDownloadAudio: {
                                viewModel.downloadAudio(id: record.id)
                            },
                            onDelete: {
                                viewModel.deleteHistoryRecord(id: record.id)
                            },
                            onRetry: {
                                viewModel.retryHistoryRecord(id: record.id)
                            }
                        )
                        if record.id != records.last?.id {
                            Divider().overlay(
                                StudioTheme.border.opacity(StudioTheme.Opacity.listDivider))
                        }
                    }
                }
            }
        }
    }

    private func modelCard(_ card: StudioModelCard) -> some View {
        StudioCard {
            HStack {
                Spacer()
                if card.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: StudioTheme.Typography.iconMedium, weight: .bold))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }

            Text(card.name)
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                .foregroundStyle(card.isMuted ? StudioTheme.textSecondary : StudioTheme.textPrimary)
            Text(card.summary)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: StudioTheme.Spacing.xSmall)

            HStack {
                Text(card.metadata)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                StudioButton(
                    title: card.actionTitle, systemImage: nil,
                    variant: card.isSelected ? .secondary : .primary
                ) {
                    handleModelSelection(card)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.modelCardMinHeight)
        .opacity(card.isMuted ? StudioTheme.Opacity.modelCardMuted : 1)
    }

    private var isLocalArchitecture: Bool {
        switch viewModel.modelDomain {
        case .stt:
            return viewModel.sttProvider == .appleSpeech || viewModel.sttProvider == .localModel
        case .llm:
            return viewModel.llmProvider == .ollama
        }
    }

    private func architectureModeButton(title: String, subtitle: String, isActive: Bool)
        -> some View
    {
        HStack(spacing: StudioTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(isActive ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                .frame(
                    width: StudioTheme.ControlSize.architectureBadge,
                    height: StudioTheme.ControlSize.architectureBadge
                )
                .overlay(
                    Image(systemName: title.contains("Local") ? "cpu.fill" : "cloud.fill")
                        .foregroundStyle(isActive ? StudioTheme.accent : StudioTheme.textSecondary)
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            Circle()
                .stroke(
                    isActive ? StudioTheme.accent : StudioTheme.border,
                    lineWidth: StudioTheme.BorderWidth.emphasis
                )
                .frame(
                    width: StudioTheme.ControlSize.selectionIndicator,
                    height: StudioTheme.ControlSize.selectionIndicator
                )
                .overlay(
                    Circle()
                        .fill(isActive ? StudioTheme.accent : Color.clear)
                        .frame(
                            width: StudioTheme.ControlSize.selectionIndicatorInner,
                            height: StudioTheme.ControlSize.selectionIndicatorInner)
                )
        }
        .padding(StudioTheme.Insets.cardCompact)
        .background(
            RoundedRectangle(
                cornerRadius: StudioTheme.CornerRadius.architectureOption, style: .continuous
            )
            .fill(isActive ? StudioTheme.surface : StudioTheme.surfaceMuted)
        )
    }

    private func handleModelSelection(_ card: StudioModelCard) {
        switch card.id {
        case "apple-speech":
            viewModel.setSTTModelSelection(.appleSpeech, suggestedModel: viewModel.whisperModel)
        case "local-stt":
            viewModel.setSTTProvider(.localModel)
        case "whisper-api":
            viewModel.setSTTModelSelection(
                .whisperAPI,
                suggestedModel: viewModel.whisperModel.isEmpty
                    ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel)
        case "ollama-local":
            viewModel.setLLMModelSelection(
                .ollama,
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
            )
        default:
            if let providerID = StudioModelProviderID(rawValue: card.id),
                let provider = LLMRemoteProvider.from(providerID: providerID)
            {
                viewModel.setLLMRemoteProvider(provider)
            }
            break
        }
    }

    private var activeModelProviderID: StudioModelProviderID {
        switch viewModel.modelDomain {
        case .stt:
            switch viewModel.sttProvider {
            case .freeModel:
                return .freeSTT
            case .appleSpeech:
                return .appleSpeech
            case .localModel:
                return .localSTT
            case .whisperAPI:
                return .whisperAPI
            case .multimodalLLM:
                return .multimodalLLM
            case .aliCloud:
                return .aliCloud
            case .doubaoRealtime:
                return .doubaoRealtime
            }
        case .llm:
            return viewModel.llmProvider == .ollama
                ? .ollama : viewModel.llmRemoteProvider.studioProviderID
        }
    }

    private var modelProviderCards: [StudioModelCard] {
        switch viewModel.modelDomain {
        case .stt:
            return [
                StudioModelCard(
                    id: StudioModelProviderID.freeSTT.rawValue,
                    name: STTProvider.freeModel.displayName,
                    summary: L("settings.models.card.freeSTT.summary"),
                    badge: L("settings.models.badge.free"),
                    metadata: viewModel.freeSTTModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.freeSTTModel,
                    isSelected: viewModel.sttProvider == .freeModel,
                    isMuted: false,
                    actionTitle: L("settings.models.useRemote")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.whisperAPI.rawValue,
                    name: STTProvider.whisperAPI.displayName,
                    summary: L("settings.models.card.whisper.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.whisperModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.whisperModel,
                    isSelected: viewModel.sttProvider == .whisperAPI,
                    isMuted: false,
                    actionTitle: L("settings.models.useRemote")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.localSTT.rawValue,
                    name: L("settings.models.localModels"),
                    summary: L("settings.models.card.localSTT.summary"),
                    badge: L("settings.models.badge.local"),
                    metadata: viewModel.localSTTModel.displayName,
                    isSelected: viewModel.sttProvider == .localModel,
                    isMuted: false,
                    actionTitle: L("settings.models.useLocal")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.multimodalLLM.rawValue,
                    name: STTProvider.multimodalLLM.displayName,
                    summary: L("settings.models.card.multimodal.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.multimodalLLMModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.multimodalLLMModel,
                    isSelected: viewModel.sttProvider == .multimodalLLM,
                    isMuted: false,
                    actionTitle: L("settings.models.useMultimodal")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.aliCloud.rawValue,
                    name: STTProvider.aliCloud.displayName,
                    summary: L("settings.models.card.aliCloud.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.builtInDefaultModel"),
                    isSelected: viewModel.sttProvider == .aliCloud,
                    isMuted: false,
                    actionTitle: L("settings.models.useAliCloud")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.doubaoRealtime.rawValue,
                    name: STTProvider.doubaoRealtime.displayName,
                    summary: L("settings.models.card.doubao.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.builtInDefaultProfile"),
                    isSelected: viewModel.sttProvider == .doubaoRealtime,
                    isMuted: false,
                    actionTitle: L("settings.models.useDoubao")
                ),
            ]
        case .llm:
            return [
                StudioModelCard(
                    id: StudioModelProviderID.ollama.rawValue,
                    name: LLMProvider.ollama.displayName,
                    summary: L("settings.models.card.ollama.summary"),
                    badge: L("settings.models.badge.local"),
                    metadata: viewModel.ollamaModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.ollamaModel,
                    isSelected: viewModel.llmProvider == .ollama,
                    isMuted: false,
                    actionTitle: L("settings.models.useLocal")
                )
            ]
                + LLMRemoteProvider.allCases.map { provider in
                    StudioModelCard(
                        id: provider.studioProviderID.rawValue,
                        name: provider.displayName,
                        summary: L("settings.models.card.\(provider.rawValue).summary"),
                        badge: provider == .freeModel
                            ? L("settings.models.badge.free")
                            : provider.apiStyle == .openAICompatible
                            ? L("settings.models.badge.api") : L("settings.models.badge.native"),
                        metadata: metadata(for: provider),
                        isSelected: viewModel.llmProvider == .openAICompatible
                            && viewModel.llmRemoteProvider == provider,
                        isMuted: false,
                        actionTitle: L("settings.models.useRemote")
                    )
                }
        }
    }

    private var modelOverviewPanel: some View {
        StudioCard {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                        )
                        .fill(StudioTheme.accentSoft)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(
                                systemName: viewModel.modelDomain == .stt
                                    ? "waveform.and.mic" : "sparkles.rectangle.stack"
                            )
                            .foregroundStyle(StudioTheme.accent)
                        )

                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(modelOverviewTitle)
                                .font(
                                    .studioDisplay(
                                        StudioTheme.Typography.sectionTitle, weight: .semibold)
                                )
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(modelOverviewSubtitle)
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }

                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        StudioPill(
                            title: modelOverviewModePill, tone: modelOverviewModeTone,
                            fill: modelOverviewModeFill)
                        StudioPill(title: modelOverviewProviderPill)
                        if let extraPill = modelOverviewExtraPill {
                            StudioPill(title: extraPill)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: StudioTheme.Spacing.small) {
                    Text(modelOverviewModelName)
                        .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(modelOverviewModelHint)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                    StudioButton(
                        title: L("settings.models.editCurrentProvider"), systemImage: nil,
                        variant: .secondary
                    ) {
                        viewModel.focusModelProvider(activeModelProviderID)
                    }
                }
            }
        }
    }

    private var focusedProviderConfigurationPanel: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                            Text(focusedProviderTitle)
                                .font(
                                    .studioDisplay(
                                        StudioTheme.Typography.sectionTitle, weight: .semibold)
                                )
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(focusedProviderSubtitle)
                                .font(.studioBody(StudioTheme.Typography.bodySmall))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }

                        Spacer()

                        if viewModel.focusedModelProvider == activeModelProviderID {
                            StudioPill(
                                title: L("settings.models.active"),
                                tone: StudioTheme.success,
                                fill: StudioTheme.success.opacity(0.12)
                            )
                        } else {
                            StudioButton(
                                title: L("settings.models.useAsDefault"),
                                systemImage: "checkmark.circle.fill", variant: .secondary
                            ) {
                                applyFocusedProviderAsDefault()
                            }
                        }
                    }
                }

                focusedProviderForm

                if [
                    StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .ollama, .aliCloud,
                    .doubaoRealtime,
                ].contains(viewModel.focusedModelProvider) || focusedLLMRemoteProvider != nil {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        StudioButton(
                            title: L("common.save"), systemImage: "checkmark", variant: .primary
                        ) {
                            viewModel.applyModelConfiguration()
                        }
                        if viewModel.focusedModelProvider == .ollama
                            || focusedLLMRemoteProvider != nil
                        {
                            StudioButton(
                                title: viewModel.llmConnectionTestState == .testing
                                    ? L("settings.models.testingConnection") : L("common.test"),
                                systemImage: viewModel.llmConnectionTestState == .testing
                                    ? nil : "network",
                                variant: .secondary,
                                isDisabled: viewModel.llmConnectionTestState == .testing,
                                isLoading: viewModel.llmConnectionTestState == .testing
                            ) {
                                viewModel.testLLMConnection()
                            }
                        } else if [
                            StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .aliCloud,
                            .doubaoRealtime,
                        ].contains(viewModel.focusedModelProvider) {
                            StudioButton(
                                title: viewModel.sttConnectionTestState == .testing
                                    ? L("settings.models.testingConnection") : L("common.test"),
                                systemImage: viewModel.sttConnectionTestState == .testing
                                    ? nil : "network",
                                variant: .secondary,
                                isDisabled: viewModel.sttConnectionTestState == .testing,
                                isLoading: viewModel.sttConnectionTestState == .testing
                            ) {
                                viewModel.testSTTConnection()
                            }
                        }
                        Spacer()
                    }

                    if viewModel.focusedModelProvider == .ollama || focusedLLMRemoteProvider != nil
                    {
                        connectionTestResultView(viewModel.llmConnectionTestState)
                    } else if [
                        StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .aliCloud,
                        .doubaoRealtime,
                    ].contains(viewModel.focusedModelProvider) {
                        connectionTestResultView(viewModel.sttConnectionTestState)
                    }
                }

                if viewModel.focusedModelProvider == .ollama {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        StudioButton(
                            title: viewModel.isPreparingOllama
                                ? L("settings.models.preparing")
                                : (viewModel.isOllamaFailed
                                    ? L("common.retry") : L("settings.models.prepareLocalModel")),
                            systemImage: viewModel.isPreparingOllama
                                ? nil
                                : (viewModel.isOllamaFailed
                                    ? "arrow.clockwise" : "arrow.down.circle"),
                            variant: .primary
                        ) {
                            viewModel.prepareOllamaModel()
                        }

                        Text(viewModel.ollamaStatus)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }

                if viewModel.focusedModelProvider == .localSTT {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        if viewModel.localSTTNeedsRetry {
                            StudioButton(
                                title: viewModel.localSTTPreparationProgress > 0
                                    ? L("common.retry") : L("settings.models.prepareLocalModel"),
                                systemImage: viewModel.localSTTPreparationProgress > 0
                                    ? "arrow.clockwise" : "arrow.down.circle",
                                variant: .primary
                            ) {
                                viewModel.prepareLocalSTTModel()
                            }
                        }

                        HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                            ProgressView(value: viewModel.localSTTPreparationProgress, total: 1)
                                .progressViewStyle(.linear)
                                .tint(viewModel.localSTTPreparationTint)

                            Text(viewModel.localSTTPreparationPercentText)
                                .font(
                                    .studioBody(StudioTheme.Typography.caption, weight: .semibold)
                                )
                                .foregroundStyle(StudioTheme.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }

                        Text(viewModel.localSTTPreparationDetail)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)

                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                                Text(L("settings.models.storagePath"))
                                    .font(
                                        .studioBody(
                                            StudioTheme.Typography.caption, weight: .semibold)
                                    )
                                    .foregroundStyle(StudioTheme.textSecondary)

                                Spacer(minLength: 0)

                                Button {
                                    viewModel.copyLocalSTTStoragePath()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(
                                            .system(
                                                size: StudioTheme.Typography.iconXSmall,
                                                weight: .semibold)
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: StudioTheme.CornerRadius.medium,
                                                style: .continuous
                                            )
                                            .fill(StudioTheme.surfaceMuted)
                                        )
                                }
                                .buttonStyle(StudioInteractiveButtonStyle())

                                Button {
                                    viewModel.openLocalSTTStorageFolder()
                                } label: {
                                    Image(systemName: "folder")
                                        .font(
                                            .system(
                                                size: StudioTheme.Typography.iconXSmall,
                                                weight: .semibold)
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: StudioTheme.CornerRadius.medium,
                                                style: .continuous
                                            )
                                            .fill(StudioTheme.surfaceMuted)
                                        )
                                }
                                .buttonStyle(StudioInteractiveButtonStyle())
                            }

                            Text(viewModel.localSTTStoragePath)
                                .font(.studioMono(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(viewModel.localSTTStatus)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }

            }
        }
    }

    @ViewBuilder
    private var focusedProviderForm: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
            switch viewModel.focusedModelProvider {
            case .appleSpeech:
                Text(L("settings.models.appleSpeech.quickest"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)

            case .freeSTT:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                        Text(L("settings.models.freeSTT.noSources"))
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textTertiary)
                    } else {
                        StudioMenuPicker(
                            options: FreeSTTModelRegistry.suggestedModelNames.map { ($0, $0) },
                            selection: Binding(
                                get: { viewModel.freeSTTModel },
                                set: viewModel.setFreeSTTModel
                            ),
                            width: 320
                        )
                    }

                    Text(L("settings.models.freeSTT.hint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)

                    if !FreeSTTModelRegistry.sources.isEmpty {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(L("settings.models.freeSTT.availableSources"))
                                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                .foregroundStyle(StudioTheme.textSecondary)
                            ForEach(FreeSTTModelRegistry.sourceSummaryLines(), id: \.self) { line in
                                Text(line)
                                    .font(.studioMono(StudioTheme.Typography.caption))
                                    .foregroundStyle(StudioTheme.textTertiary)
                            }
                        }
                    }
                }

            case .localSTT:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                    Text(L("settings.models.localModel"))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)

                    ForEach(LocalSTTModel.allCases, id: \.self) { model in
                        localSTTModelOptionCard(model)
                    }
                }
                .confirmationDialog(
                    localSTTPendingRedownload.map {
                        L("settings.models.redownloadDialog.title", $0.displayName)
                    } ?? "",
                    isPresented: Binding(
                        get: { localSTTPendingRedownload != nil },
                        set: { if !$0 { localSTTPendingRedownload = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(L("settings.models.redownload"), role: .destructive) {
                        if let model = localSTTPendingRedownload {
                            viewModel.redownloadLocalSTTModel(model)
                            localSTTPendingRedownload = nil
                        }
                    }
                    Button(L("common.cancel"), role: .cancel) {
                        localSTTPendingRedownload = nil
                    }
                } message: {
                    Text(L("settings.models.redownloadDialog.message"))
                }
                .confirmationDialog(
                    localSTTPendingDelete.map {
                        L("settings.models.deleteDialog.title", $0.displayName)
                    } ?? "",
                    isPresented: Binding(
                        get: { localSTTPendingDelete != nil },
                        set: { if !$0 { localSTTPendingDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(L("common.delete"), role: .destructive) {
                        if let model = localSTTPendingDelete {
                            viewModel.deleteLocalSTTModel(model)
                            localSTTPendingDelete = nil
                        }
                    }
                    Button(L("common.cancel"), role: .cancel) {
                        localSTTPendingDelete = nil
                    }
                } message: {
                    Text(L("settings.models.deleteDialog.message"))
                }

            case .whisperAPI:
                StudioSuggestedTextInputCard(
                    label: L("settings.models.transcriptionEndpoint"),
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: Binding(
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL),
                    suggestions: whisperEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.whisperModels[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions
                )
                StudioTextInputCard(
                    label: L("common.apiKey"), placeholder: "sk-...",
                    text: Binding(
                        get: { viewModel.whisperAPIKey }, set: viewModel.setWhisperAPIKey),
                    secure: true)

            case .ollama:
                StudioSuggestedTextInputCard(
                    label: L("settings.models.ollama.baseURL"),
                    placeholder: "http://127.0.0.1:11434",
                    text: Binding(
                        get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL),
                    suggestions: ollamaEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: L("settings.models.localModel"),
                    placeholder: "qwen2.5:7b",
                    text: Binding(get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel),
                    suggestions: ollamaModelSuggestions
                )
                Toggle(
                    L("settings.models.ollama.autoInstall"),
                    isOn: Binding(
                        get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup)
                )
                .toggleStyle(.switch)

            case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen,
                .zhipu, .minimax:
                llmRemoteProviderForm

            case .multimodalLLM:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.apiEndpoint"),
                        placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMBaseURL },
                            set: viewModel.setMultimodalLLMBaseURL),
                        suggestions: multimodalEndpointSuggestions
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMModel },
                            set: viewModel.setMultimodalLLMModel),
                        suggestions: multimodalModelSuggestions
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.multimodalLLMAPIKey },
                            set: viewModel.setMultimodalLLMAPIKey), secure: true)
                    Text(L("settings.models.multimodalLLM.audioHint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

            case .aliCloud:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.aliCloudAPIKey }, set: viewModel.setAliCloudAPIKey),
                        secure: true
                    ) {
                        Button {
                            NSWorkspace.shared.open(
                                URL(
                                    string: "https://bailian.console.aliyun.com?tab=model#/api-key")!
                            )
                        } label: {
                            Text(L("settings.models.aliCloud.getAPIKey"))
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

            case .doubaoRealtime:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("settings.models.doubao.appID"), placeholder: "APPID",
                        text: Binding(get: { viewModel.doubaoAppID }, set: viewModel.setDoubaoAppID)
                    )
                    StudioTextInputCard(
                        label: L("settings.models.doubao.accessToken"), placeholder: "access-token",
                        text: Binding(
                            get: { viewModel.doubaoAccessToken },
                            set: viewModel.setDoubaoAccessToken), secure: true
                    ) {
                        Button {
                            NSWorkspace.shared.open(
                                URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!
                            )
                        } label: {
                            Text(L("settings.models.doubao.docs"))
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionTestResultView(_ state: ConnectionTestState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text(L("settings.models.testingConnection"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        case .success(let firstMs, let totalMs, let preview):
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.success)
                    Text(L("settings.models.connectionSuccess", firstMs, totalMs))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(StudioTheme.Spacing.small)
                        .background(
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous
                            )
                            .fill(StudioTheme.surfaceMuted)
                        )
                }
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.danger)
                Text(message)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelRoutingPanel: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                StudioSectionTitle(title: L("settings.models.routing"))
                providerFactRow(title: modelRoutingPrimaryTitle, value: modelRoutingPrimaryValue)
                if let title = modelRoutingSecondaryTitle, let value = modelRoutingSecondaryValue {
                    providerFactRow(title: title, value: value)
                }

                HStack {
                    StudioButton(
                        title: L("settings.models.applyConfiguration"), systemImage: "bolt.fill",
                        variant: .primary
                    ) {
                        viewModel.applyModelConfiguration()
                    }
                    if viewModel.modelDomain == .llm && viewModel.llmProvider == .ollama {
                        StudioButton(
                            title: L("settings.models.prepareOllama"), systemImage: nil,
                            variant: .secondary
                        ) {
                            viewModel.prepareOllamaModel()
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func modelProviderSelectionCard(_ card: StudioModelCard) -> some View {
        let providerID = StudioModelProviderID(rawValue: card.id) ?? activeModelProviderID
        let isFocused = viewModel.focusedModelProvider == providerID

        return Button {
            viewModel.focusModelProvider(providerID)
        } label: {
            StudioCard(padding: StudioTheme.Insets.cardCompact) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.xSmall) {
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                        )
                        .fill(providerBadgeBackground(for: providerID, isFocused: isFocused))
                        .frame(
                            width: StudioTheme.ControlSize.modelProviderBadge,
                            height: StudioTheme.ControlSize.modelProviderBadge
                        )
                        .overlay(
                            providerIconView(for: providerID, isFocused: isFocused)
                        )

                        Text(card.name)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Circle()
                            .fill(card.isSelected ? StudioTheme.success : StudioTheme.border)
                            .frame(
                                width: StudioTheme.ControlSize.modelProviderStatusDot,
                                height: StudioTheme.ControlSize.modelProviderStatusDot)
                    }

                    Text(card.summary)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)

                    HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                        Text(card.metadata)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if card.isSelected {
                            StudioPill(
                                title: L("settings.models.active"),
                                tone: StudioTheme.success,
                                fill: StudioTheme.success.opacity(0.12)
                            )
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isFocused ? StudioTheme.accent.opacity(0.62) : Color.clear,
                        lineWidth: StudioTheme.BorderWidth.emphasis)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func providerFactRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 86, alignment: .leading)

            Text(value)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func metadata(for provider: LLMRemoteProvider) -> String {
        let model =
            viewModel.llmRemoteProvider == provider ? viewModel.llmModel : provider.defaultModel
        return model.isEmpty ? L("settings.models.modelNotConfigured") : model
    }

    private func providerBadgeBackground(for provider: StudioModelProviderID, isFocused: Bool)
        -> Color
    {
        if providerLogoResourceName(for: provider) != nil {
            return isFocused ? Color.white.opacity(0.98) : Color.white.opacity(0.92)
        }

        return isFocused ? StudioTheme.accentSoft : StudioTheme.surfaceMuted
    }

    @ViewBuilder
    private func providerIconView(for provider: StudioModelProviderID, isFocused: Bool) -> some View
    {
        if let image = providerLogoImage(for: provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(9)
        } else {
            Image(systemName: iconName(for: provider))
                .font(
                    .system(
                        size: StudioTheme.ControlSize.modelProviderBadgeSymbol, weight: .semibold)
                )
                .foregroundStyle(isFocused ? StudioTheme.accent : StudioTheme.textSecondary)
        }
    }

    private func providerLogoImage(for provider: StudioModelProviderID) -> NSImage? {
        guard let resourceName = providerLogoResourceName(for: provider) else { return nil }

        let url =
            Bundle.module.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Resources/Providers"
            )
            ?? Bundle.module.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Providers")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func providerLogoResourceName(for provider: StudioModelProviderID) -> String? {
        switch provider {
        case .freeSTT:
            return nil
        case .whisperAPI, .multimodalLLM:
            return "openai"
        case .ollama:
            return "ollama"
        case .freeModel:
            return nil
        case .openRouter:
            return "openrouter"
        case .openAI:
            return "openai"
        case .anthropic:
            return "claude-color"
        case .gemini:
            return "gemini-color"
        case .deepSeek:
            return "deepseek-color"
        case .kimi:
            return "moonshot"
        case .qwen:
            return "qwen-color"
        case .zhipu:
            return "zhipu-color"
        case .minimax:
            return "minimax-color"
        case .aliCloud:
            return "bailian-color"
        case .doubaoRealtime:
            return "doubao-color"
        default:
            return nil
        }
    }

    private func localSTTModelOptionCard(_ model: LocalSTTModel) -> some View {
        let isSelected = viewModel.localSTTModel == model
        let specs = model.specs

        return Button {
            viewModel.setLocalSTTModel(model)
        } label: {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                        Text(model.displayName)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        Text(specs.summary)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        StudioPill(
                            title: L("settings.models.selected"),
                            tone: StudioTheme.accent,
                            fill: StudioTheme.accentSoft
                        )
                    }
                }

                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    localSTTSpecPill(model.displayName)
                    localSTTSpecPill("\(specs.parameterValue) parameters")
                    localSTTSpecPill(specs.sizeValue)
                }
            }
            .padding(StudioTheme.Insets.cardCompact)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(
                        isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted.opacity(0.45)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isSelected
                            ? StudioTheme.accent.opacity(0.65) : StudioTheme.border.opacity(0.75),
                        lineWidth: isSelected
                            ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .contextMenu {
            Button {
                if viewModel.isModelDownloaded(model) {
                    localSTTPendingRedownload = model
                } else {
                    viewModel.setLocalSTTModel(model)
                    viewModel.prepareLocalSTTModel()
                }
            } label: {
                Label(L("settings.models.redownload"), systemImage: "arrow.clockwise")
            }

            if viewModel.isModelDownloaded(model) {
                Divider()
                Button(role: .destructive) {
                    localSTTPendingDelete = model
                } label: {
                    Label(L("settings.models.deleteModelFiles"), systemImage: "trash")
                }
            }
        }
    }

    private func localSTTSpecPill(_ text: String) -> some View {
        Text(text)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, StudioTheme.Insets.pillHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioTheme.surface)
            )
    }

    private func providerIsConfigured(_ provider: StudioModelProviderID) -> Bool {
        switch provider {
        case .appleSpeech:
            return true
        case .localSTT:
            return true
        case .freeSTT:
            return !viewModel.freeSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && FreeSTTModelRegistry.resolve(modelName: viewModel.freeSTTModel) != nil
        case .whisperAPI:
            return !viewModel.whisperBaseURL.isEmpty
        case .ollama:
            return !viewModel.ollamaModel.isEmpty
        case .freeModel:
            return !viewModel.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && FreeLLMModelRegistry.resolve(modelName: viewModel.llmModel) != nil
        case .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return !viewModel.llmAPIKey.isEmpty && !viewModel.llmBaseURL.isEmpty
                && !viewModel.llmModel.isEmpty
        case .multimodalLLM:
            return !viewModel.multimodalLLMBaseURL.isEmpty && !viewModel.multimodalLLMModel.isEmpty
        case .aliCloud:
            return !viewModel.aliCloudAPIKey.isEmpty
        case .doubaoRealtime:
            return !viewModel.doubaoAppID.isEmpty && !viewModel.doubaoAccessToken.isEmpty
        }
    }

    private func applyFocusedProviderAsDefault() {
        if viewModel.focusedLLMProviderMissingAPIKey() {
            llmActivationMissingAPIKeyProviderName = focusedProviderTitle
            return
        }

        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            viewModel.setSTTModelSelection(.appleSpeech, suggestedModel: viewModel.whisperModel)
        case .localSTT:
            viewModel.setSTTProvider(.localModel)
        case .freeSTT:
            viewModel.setSTTModelSelection(.freeModel, suggestedModel: viewModel.freeSTTModel)
        case .whisperAPI:
            viewModel.setSTTModelSelection(
                .whisperAPI,
                suggestedModel: viewModel.whisperModel.isEmpty
                    ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel)
        case .ollama:
            viewModel.applyModelConfiguration(shouldShowToast: false)
            viewModel.setLLMModelSelection(
                .ollama,
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
            )
            viewModel.prepareOllamaModel()
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            if let provider = focusedLLMRemoteProvider {
                viewModel.applyModelConfiguration(shouldShowToast: false)
                viewModel.setLLMRemoteProvider(provider)
                if viewModel.llmModel.isEmpty {
                    viewModel.setLLMModel(provider.defaultModel)
                }
            }
        case .multimodalLLM:
            viewModel.setSTTModelSelection(
                .multimodalLLM,
                suggestedModel: viewModel.multimodalLLMModel.isEmpty
                    ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel)
        case .aliCloud:
            viewModel.setSTTProvider(.aliCloud)
        case .doubaoRealtime:
            viewModel.setSTTProvider(.doubaoRealtime)
        }
    }

    private func iconName(for provider: StudioModelProviderID) -> String {
        switch provider {
        case .appleSpeech:
            return "waveform"
        case .localSTT:
            return "laptopcomputer.and.arrow.down"
        case .freeSTT:
            return "giftcard"
        case .whisperAPI:
            return "dot.radiowaves.left.and.right"
        case .ollama:
            return "cpu"
        case .freeModel:
            return "giftcard"
        case .customLLM:
            return "xmark.triangle.circle.square.fill"
        case .openRouter:
            return "arrow.triangle.branch"
        case .openAI:
            return "circle.hexagongrid"
        case .anthropic:
            return "sun.max"
        case .gemini:
            return "diamond"
        case .deepSeek:
            return "bird"
        case .kimi:
            return "moon.stars"
        case .qwen:
            return "cloud"
        case .zhipu:
            return "dot.scope"
        case .minimax:
            return "sparkles"
        case .multimodalLLM:
            return "brain.filled.head.profile"
        case .aliCloud:
            return "antenna.radiowaves.left.and.right"
        case .doubaoRealtime:
            return "bolt.horizontal.circle"
        }
    }

    private var modelProviderSectionTitle: String {
        viewModel.modelDomain == .stt
            ? L("settings.models.providers.stt") : L("settings.models.providers.llm")
    }

    private var modelProviderSectionSubtitle: String {
        viewModel.modelDomain == .stt
            ? L("settings.models.providers.sttSubtitle")
            : L("settings.models.providers.llmSubtitle")
    }

    private var modelOverviewTitle: String {
        viewModel.modelDomain == .stt
            ? L("settings.models.overview.sttTitle") : L("settings.models.overview.llmTitle")
    }

    private var modelOverviewSubtitle: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return L("settings.models.overview.appleSpeech")
        case .localSTT:
            return L("settings.models.overview.localSTT")
        case .freeSTT:
            return L("settings.models.overview.freeSTT")
        case .whisperAPI:
            return L("settings.models.overview.whisper")
        case .ollama:
            return L("settings.models.overview.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return L("settings.models.overview.remoteProvider", activeLLMRemoteProvider.displayName)
        case .multimodalLLM:
            return L("settings.models.overview.multimodal")
        case .aliCloud:
            return L("settings.models.overview.aliCloud")
        case .doubaoRealtime:
            return L("settings.models.overview.doubao")
        }
    }

    private var modelOverviewProviderPill: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return STTProvider.appleSpeech.displayName
        case .localSTT:
            return STTProvider.localModel.displayName
        case .freeSTT:
            return STTProvider.freeModel.displayName
        case .whisperAPI:
            return STTProvider.whisperAPI.displayName
        case .ollama:
            return LLMProvider.ollama.displayName
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return activeLLMRemoteProvider.displayName
        case .multimodalLLM:
            return STTProvider.multimodalLLM.displayName
        case .aliCloud:
            return STTProvider.aliCloud.displayName
        case .doubaoRealtime:
            return STTProvider.doubaoRealtime.displayName
        }
    }

    private var modelOverviewModePill: String {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return L("settings.models.mode.local")
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
            .qwen, .zhipu, .minimax, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return L("settings.models.mode.remote")
        }
    }

    private var modelOverviewModeTone: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return StudioTheme.success
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
            .qwen, .zhipu, .minimax, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return StudioTheme.accent
        }
    }

    private var modelOverviewModeFill: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            return StudioTheme.success.opacity(0.12)
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
            .qwen, .zhipu, .minimax, .multimodalLLM, .aliCloud, .doubaoRealtime:
            return StudioTheme.accentSoft
        }
    }

    private var modelOverviewExtraPill: String? {
        if viewModel.modelDomain == .stt {
            return viewModel.appleSpeechFallback
                ? L("settings.models.fallback.enabled") : L("settings.models.fallback.off")
        }

        return providerIsConfigured(activeModelProviderID)
            ? L("settings.models.configured") : L("settings.models.needsSetup")
    }

    private var modelOverviewModelName: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return STTProvider.appleSpeech.displayName
        case .localSTT:
            return viewModel.localSTTModel.displayName
        case .freeSTT:
            return viewModel.freeSTTModel.isEmpty
                ? L("settings.models.modelNotConfigured") : viewModel.freeSTTModel
        case .whisperAPI:
            return viewModel.whisperModel.isEmpty
                ? OpenAIAudioModelCatalog.whisperModels[0] : viewModel.whisperModel
        case .ollama:
            return viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return viewModel.llmModel.isEmpty
                ? activeLLMRemoteProvider.defaultModel : viewModel.llmModel
        case .multimodalLLM:
            return viewModel.multimodalLLMModel.isEmpty
                ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel
        case .aliCloud:
            return AliCloudASRDefaults.model
        case .doubaoRealtime:
            return L("settings.models.doubao.productName")
        }
    }

    private var modelOverviewModelHint: String {
        providerIsConfigured(activeModelProviderID)
            ? L("settings.models.readyForUse") : L("settings.models.configurationNeeded")
    }

    private var focusedProviderTitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            return STTProvider.appleSpeech.displayName
        case .localSTT:
            return L("settings.models.localSpeechModels")
        case .freeSTT:
            return STTProvider.freeModel.displayName
        case .whisperAPI:
            return STTProvider.whisperAPI.displayName
        case .ollama:
            return LLMProvider.ollama.displayName
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return focusedLLMRemoteProvider?.displayName ?? LLMProvider.openAICompatible.displayName
        case .multimodalLLM:
            return STTProvider.multimodalLLM.displayName
        case .aliCloud:
            return STTProvider.aliCloud.displayName
        case .doubaoRealtime:
            return STTProvider.doubaoRealtime.displayName
        }
    }

    private var focusedProviderSubtitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            return L("settings.models.focused.appleSpeech")
        case .localSTT:
            return L("settings.models.focused.localSTT")
        case .freeSTT:
            return L("settings.models.focused.freeSTT")
        case .whisperAPI:
            return L("settings.models.focused.whisper")
        case .ollama:
            return L("settings.models.focused.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return L(
                "settings.models.focused.remoteProvider",
                focusedLLMRemoteProvider?.displayName ?? LLMProvider.openAICompatible.displayName)
        case .multimodalLLM:
            return L("settings.models.focused.multimodal")
        case .aliCloud:
            return L("settings.models.focused.aliCloud")
        case .doubaoRealtime:
            return L("settings.models.focused.doubao")
        }
    }

    private var modelRoutingPrimaryTitle: String {
        viewModel.modelDomain == .stt
            ? L("settings.models.routing.primaryRecognizer")
            : L("settings.models.routing.primaryRuntime")
    }

    private var modelRoutingPrimaryValue: String {
        switch activeModelProviderID {
        case .appleSpeech:
            return L("settings.models.routing.appleSpeech")
        case .localSTT:
            return L("settings.models.routing.localSTT")
        case .freeSTT:
            return L("settings.models.routing.freeSTT")
        case .whisperAPI:
            return L("settings.models.routing.whisper")
        case .ollama:
            return L("settings.models.routing.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
            .minimax:
            return L("settings.models.routing.remoteProvider", activeLLMRemoteProvider.displayName)
        case .multimodalLLM:
            return L("settings.models.routing.multimodal")
        case .aliCloud:
            return L("settings.models.routing.aliCloud")
        case .doubaoRealtime:
            return L("settings.models.routing.doubao")
        }
    }

    private var modelRoutingSecondaryTitle: String? {
        if viewModel.modelDomain == .stt {
            return L("settings.models.routing.fallback")
        }

        return activeModelProviderID == .ollama
            ? L("settings.models.routing.localSetup") : L("settings.models.routing.readiness")
    }

    private var modelRoutingSecondaryValue: String? {
        if viewModel.modelDomain == .stt {
            return viewModel.appleSpeechFallback
                ? L("settings.models.routing.fallbackEnabled")
                : L("settings.models.routing.fallbackDisabled")
        }

        if activeModelProviderID == .ollama {
            return viewModel.ollamaAutoSetup
                ? L("settings.models.routing.localSetupAutomatic")
                : L("settings.models.routing.localSetupManual")
        }

        return providerIsConfigured(activeLLMRemoteProvider.studioProviderID)
            ? L("settings.models.routing.readinessConfigured")
            : L("settings.models.routing.readinessNeedsSetup")
    }

}
