import AppKit
import SwiftUI

// swiftlint:disable file_length
private enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all
    case automatic
    case manual

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            L("vocabulary.filter.all")
        case .automatic:
            L("vocabulary.filter.automatic")
        case .manual:
            L("vocabulary.filter.manual")
        }
    }

    var source: VocabularySource? {
        switch self {
        case .all:
            nil
        case .automatic:
            .automatic
        case .manual:
            .manual
        }
    }

    var iconName: String {
        switch self {
        case .all:
            "line.3.horizontal.decrease.circle"
        case .automatic:
            "sparkles"
        case .manual:
            "hand.draw"
        }
    }
}

// swiftlint:disable:next type_body_length
struct StudioView: View {
    private struct ShortcutConfiguration {
        let title: String
        let subtitle: String
        let footnote: String
        let icon: String
        let badgeSymbol: String
        let binding: HotkeyBinding?
        let isDefault: Bool
        let isThisRecording: Bool
    }

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
    @State private var editingVocabularyEntry: VocabularyEntry?
    @State private var newVocabularyTerm = ""
    @State private var personaPendingDeletion: PersonaProfile?
    @State private var localSTTPendingDelete: LocalSTTModel? = nil
    @State private var localSTTPendingRedownload: LocalSTTModel? = nil
    @State private var llmActivationMissingAPIKeyProviderName: String?
    @State private var isMCPServerDialogPresented = false
    @State private var mcpServerPendingDeletion: MCPServerConfig? = nil
    @State private var agentJobPendingDeletion: AgentJob?
    @State private var showingClearAllJobsConfirmation = false
    @State private var showingClearHistoryConfirmation = false
    @State private var agentConfigurationTab: AgentConfigurationTab = .general
    @State private var isAdvancedSettingsExpanded = false
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var authState = AuthState.shared

    var body: some View {
        StudioShell(
            currentSection: viewModel.currentSection,
            onSelect: viewModel.navigate,
            onOpenAbout: { AboutWindowController.shared.show() },
            onSendFeedbackEmail: sendFeedbackEmail,
            onOpenGitHubIssue: openGitHubIssue,
            onAccountAction: handleAccountAction,
            searchText: $viewModel.searchQuery,
            searchPlaceholder: viewModel.currentSection.searchPlaceholder,
            agentEnabled: viewModel.agentFrameworkEnabled,
            isLoggedIn: authState.isLoggedIn,
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
                height: viewModel.currentSection == .models ? viewportHeight : nil, alignment: .top,
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
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
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
                            .fill(StudioTheme.surface),
                    )
                    .overlay(
                        Capsule().stroke(
                            StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin,
                        ),
                    )
                    .padding(.bottom, StudioTheme.Insets.toastBottom)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { isAddingVocabulary || editingVocabularyEntry != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    isAddingVocabulary = false
                    editingVocabularyEntry = nil
                    newVocabularyTerm = ""
                },
            ),
        ) {
            vocabularyAddSheet
        }
        .confirmationDialog(
            L("settings.personas.deleteDialog.title"),
            isPresented: Binding(
                get: { personaPendingDeletion != nil },
                set: { if !$0 { personaPendingDeletion = nil } },
            ),
            titleVisibility: .visible,
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
                set: { if !$0 { llmActivationMissingAPIKeyProviderName = nil } },
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
            },
        )
        .sheet(isPresented: $isMCPServerDialogPresented) {
            mcpServerDialog
        }
        .confirmationDialog(
            L("agent.mcp.deleteDialog.title"),
            isPresented: Binding(
                get: { mcpServerPendingDeletion != nil },
                set: { if !$0 { mcpServerPendingDeletion = nil } },
            ),
            titleVisibility: .visible,
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
        .confirmationDialog(
            L("history.clearDialog.title"),
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible,
        ) {
            Button(L("common.clear"), role: .destructive) {
                viewModel.clearHistory()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("history.clearDialog.message"))
        }
        .sheet(isPresented: $viewModel.showingJobsPage) {
            agentJobsSheet
        }
    }

    private func sendFeedbackEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "mylxsw@aicode.cc"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Typeflux Feedback"),
            URLQueryItem(
                name: "body", value: "Hi,\n\nI want to share some feedback about Typeflux:\n",
            ),
        ]

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openGitHubIssue() {
        guard let url = URL(string: "https://github.com/mylxsw/typeflux/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleAccountAction() {
        guard authState.isLoggedIn else {
            LoginWindowController.shared.show()
            return
        }

        Task { @MainActor in
            switch await authState.refreshProfile() {
            case .authenticated, .failed:
                viewModel.navigate(to: .account)
            case .unauthenticated:
                LoginWindowController.shared.show()
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
            StudioHeroHeader(
                eyebrow: viewModel.currentSection.eyebrow,
                title: viewModel.currentSection.heading,
                subtitle: viewModel.currentSection.subheading,
                badge: viewModel.currentSection == .agent ? "Beta" : nil,
            )

            if viewModel.currentSection == .vocabulary {
                Spacer()

                StudioButton(
                    title: L("vocabulary.action.newWord"), systemImage: "plus", variant: .primary,
                ) {
                    editingVocabularyEntry = nil
                    newVocabularyTerm = ""
                    isAddingVocabulary = true
                }
            } else if viewModel.currentSection == .agent {
                Spacer()

                StudioButton(
                    title: L("agent.jobs.title"), systemImage: "list.bullet.rectangle", variant: .secondary,
                ) {
                    viewModel.openJobsPage()
                }
            } else if viewModel.currentSection == .history {
                Spacer()

                HStack(spacing: StudioTheme.Spacing.medium) {
                    StudioIconButton(
                        systemImage: "square.and.arrow.up",
                        variant: .ghost,
                    ) {
                        viewModel.exportHistory()
                    }
                    .studioTooltip(L("history.action.exportMarkdown"), yOffset: 34)

                    StudioIconButton(
                        systemImage: "trash",
                        variant: .ghost,
                    ) {
                        showingClearHistoryConfirmation = true
                    }
                    .studioTooltip(L("common.clear"), yOffset: 34)
                }
            } else if viewModel.currentSection == .personas {
                Spacer()

                Button(action: viewModel.beginCreatingPersona) {
                    Image(systemName: "plus")
                        .foregroundStyle(.white)
                        .frame(
                            width: StudioTheme.ControlSize.personaAddButton,
                            height: StudioTheme.ControlSize.personaAddButton,
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
        case .account:
            AccountView(authState: AuthState.shared) {
                viewModel.navigate(to: .home)
            }
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
                    viewModel.displayedHistory.prefix(StudioTheme.Count.homeRecentRecords),
                ),
            )
        }
    }

    private func modelsPage(viewportHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSegmentedPicker(
                options: StudioModelDomain.allCases.map { (label: modelDomainTabTitle(for: $0), value: $0) },
                selection: Binding(
                    get: { viewModel.modelDomain },
                    set: viewModel.setModelDomain,
                ),
            )

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
                        alignment: .leading,
                    )
                    .frame(maxHeight: .infinity, alignment: .top)

                    ScrollView {
                        focusedProviderConfigurationPanel
                    }
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
            0,
        )
    }

    private func modelDomainTabTitle(for domain: StudioModelDomain) -> String {
        switch domain {
        case .stt:
            L("settings.models.domain.stt")
        case .llm:
            L("settings.models.domain.llm")
        }
    }

    private var personasPage: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.section) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                    personaRosterCard(
                        title: L("persona.none.title"),
                        subtitle: L("persona.none.subtitle"),
                        initials: "",
                        systemImage: "slash.circle",
                        metadata: L("persona.none.title"),
                        isSelected: !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == nil,
                        isActive: viewModel.activePersonaID.isEmpty,
                    ) {
                        viewModel.selectPersona(nil)
                    }

                    ForEach(viewModel.filteredPersonas) { persona in
                        personaRosterCard(
                            title: persona.name,
                            subtitle: persona.prompt,
                            initials: String(
                                persona.name.prefix(StudioTheme.Count.personaInitials),
                            ).uppercased(),
                            systemImage: nil,
                            metadata: persona.isSystem ? L("settings.personas.tag.system") : nil,
                            isSelected: viewModel.selectedPersonaID == persona.id,
                            isActive: persona.id.uuidString == viewModel.activePersonaID,
                        ) {
                            viewModel.selectPersona(persona.id)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: StudioTheme.Layout.modelProviderListWidth, alignment: .leading)

            StudioCard {
                if !viewModel.isCreatingPersonaDraft {
                    HStack {
                        Text(L("settings.personas.editTitle"))
                            .font(
                                .studioDisplay(
                                    StudioTheme.Typography.sectionTitle, weight: .semibold,
                                ),
                            )
                            .foregroundStyle(StudioTheme.textPrimary)

                        Spacer()

                        if viewModel.selectedPersonaID == nil {
                            if viewModel.activePersonaID.isEmpty {
                                StudioPill(
                                    title: L("settings.models.active"),
                                    tone: StudioTheme.success,
                                    fill: StudioTheme.success.opacity(0.12),
                                )
                            } else {
                                StudioButton(
                                    title: L("settings.models.useAsDefault"),
                                    systemImage: "checkmark.circle.fill",
                                    variant: .secondary,
                                ) {
                                    viewModel.deactivatePersonaRewrite()
                                }
                            }
                        } else if viewModel.personaRewriteEnabled
                            && !viewModel.activePersonaID.isEmpty
                            && viewModel.selectedPersonaID?.uuidString == viewModel.activePersonaID
                        {
                            StudioPill(
                                title: L("settings.models.active"),
                                tone: StudioTheme.success,
                                fill: StudioTheme.success.opacity(0.12),
                            )
                        } else {
                            StudioButton(
                                title: L("settings.models.useAsDefault"),
                                systemImage: "checkmark.circle.fill",
                                variant: .secondary,
                            ) {
                                viewModel.activateSelectedPersona()
                            }
                        }
                    }
                }

                if !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == nil {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        StudioSectionTitle(title: L("persona.none.title"))

                        Text(L("persona.none.subtitle"))
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: StudioTheme.Layout.textEditorMinHeight, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        StudioTextInputCard(
                            label: L("settings.personas.name"),
                            placeholder: L("settings.personas.namePlaceholder"),
                            text: Binding(
                                get: { viewModel.personaDraftName },
                                set: { viewModel.personaDraftName = $0 },
                            ),
                        )
                        .disabled(
                            viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft,
                        )
                        .opacity(
                            viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                                ? 0.6 : 1,
                        )
                    }

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        StudioSectionTitle(title: L("settings.personas.prompt"))

                        TextEditor(
                            text: Binding(
                                get: { viewModel.personaDraftPrompt },
                                set: { viewModel.personaDraftPrompt = $0 },
                            ),
                        )
                        .font(.studioMono(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .disabled(
                            viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft,
                        )
                        .frame(minHeight: StudioTheme.Layout.textEditorMinHeight)
                        .padding(StudioTheme.Insets.textEditor)
                        .background(
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.large, style: .continuous,
                            )
                            .fill(StudioTheme.surfaceMuted),
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.large, style: .continuous,
                            )
                            .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
                        )
                        .opacity(
                            viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
                                ? 0.6 : 1,
                        )
                    }

                    if !(viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft) {
                        HStack {
                            Spacer()
                            StudioButton(
                                title: L("common.cancel"), systemImage: nil, variant: .secondary,
                            ) {
                                viewModel.cancelPersonaEditing()
                            }
                            StudioButton(
                                title: L("common.save"),
                                systemImage: nil,
                                variant: .primary,
                                isDisabled: !viewModel.canSavePersonaDraft
                                    || !viewModel.hasPersonaDraftChanges,
                            ) {
                                viewModel.savePersonaDraft()
                            }
                        }
                    }
                }
            }
        }
    }

    private var personaProviderSelectionSection: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                StudioSettingRow(
                    title: L("settings.personas.providers.stt"),
                    subtitle: L("settings.personas.providers.stt.subtitle")
                ) {
                    StudioMenuPicker(
                        options: STTProvider.settingsDisplayOrder
                            .filter { $0 != .freeModel || !FreeSTTModelRegistry.suggestedModelNames.isEmpty }
                            .map { (label: $0.displayName, value: $0) },
                        selection: Binding(
                            get: { viewModel.sttProvider },
                            set: { viewModel.setSTTProvider($0) },
                        ),
                        width: 200,
                    )
                }

                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                StudioSettingRow(
                    title: L("settings.personas.providers.llm"),
                    subtitle: L("settings.personas.providers.llm.subtitle")
                ) {
                    StudioMenuPicker(
                        options: personaLLMProviderOptions,
                        selection: Binding(
                            get: {
                                viewModel.llmProvider == .ollama
                                    ? .ollama
                                    : viewModel.llmRemoteProvider.studioProviderID
                            },
                            set: { providerID in
                                if providerID == .ollama {
                                    viewModel.setLLMProvider(.ollama)
                                } else if let remoteProvider = LLMRemoteProvider.from(
                                    providerID: providerID,
                                ) {
                                    viewModel.setLLMRemoteProvider(remoteProvider)
                                }
                            },
                        ),
                        width: 200,
                    )
                }
            }
        }
    }

    private var personaLLMProviderOptions: [(label: String, value: StudioModelProviderID)] {
        [(label: LLMProvider.ollama.displayName, value: .ollama)] +
            LLMRemoteProvider.settingsDisplayOrder
                .filter { $0 != .freeModel || !FreeLLMModelRegistry.suggestedModelNames.isEmpty }
                .map { provider in
                    (label: provider.displayName, value: provider.studioProviderID)
                }
    }

    private func personaRosterCard(
        title: String,
        subtitle: String,
        initials: String,
        systemImage: String?,
        metadata: String?,
        isSelected: Bool,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            StudioCard(padding: StudioTheme.Insets.cardCompact) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.xSmall) {
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large,
                            style: .continuous,
                        )
                        .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                        .frame(
                            width: StudioTheme.ControlSize.modelProviderBadge,
                            height: StudioTheme.ControlSize.modelProviderBadge,
                        )
                        .overlay(
                            Group {
                                if let systemImage {
                                    Image(systemName: systemImage)
                                        .font(.system(
                                            size: StudioTheme.Typography.bodySmall,
                                            weight: .bold,
                                        ))
                                        .foregroundStyle(
                                            isSelected ? StudioTheme.accent : StudioTheme.textSecondary,
                                        )
                                } else {
                                    Text(initials)
                                        .font(.studioBody(
                                            StudioTheme.Typography.bodySmall,
                                            weight: .bold,
                                        ))
                                        .foregroundStyle(
                                            isSelected ? StudioTheme.accent : StudioTheme.textSecondary,
                                        )
                                }
                            },
                        )

                        Text(title)
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Circle()
                            .fill(isActive ? StudioTheme.success : StudioTheme.border)
                            .frame(
                                width: StudioTheme.ControlSize.modelProviderStatusDot,
                                height: StudioTheme.ControlSize.modelProviderStatusDot,
                            )
                    }

                    Text(subtitle)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)

                    if metadata != nil || isActive {
                        HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
                            if let metadata {
                                Text(metadata)
                                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if isActive {
                                StudioPill(
                                    title: L("settings.models.active"),
                                    tone: StudioTheme.success,
                                    fill: StudioTheme.success.opacity(0.12),
                                )
                            }
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isSelected ? StudioTheme.accent.opacity(0.62) : Color.clear,
                        lineWidth: StudioTheme.BorderWidth.emphasis,
                    ),
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: StudioTheme.CornerRadius.hero,
                    style: .continuous,
                ),
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("history.keep.title"),
                        subtitle: L("history.keep.subtitle"),
                    ) {
                        StudioMenuPicker(
                            options: HistoryRetentionPolicy.allCases.map {
                                (label: $0.title, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.historyRetentionPolicy },
                                set: viewModel.setHistoryRetentionPolicy,
                            ),
                            width: 140,
                        )
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("history.privacy.title"),
                        subtitle: L("history.privacy.subtitle"),
                    ) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(StudioTheme.success)
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
                                        onCopyResult: {
                                            viewModel.copyHistoryResult(id: record.id)
                                        },
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
                                        },
                                    )
                                    if record.id != section.records.last?.id {
                                        Divider().overlay(
                                            StudioTheme.border.opacity(
                                                StudioTheme.Opacity.listDivider,
                                            ),
                                        )
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
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous,
                    )
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill)),
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous,
                    )
                    .stroke(
                        StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: StudioTheme.BorderWidth.thin,
                    ),
                )
            }

            StudioCard {
                Group {
                    if filteredVocabularyEntries.isEmpty {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                            Text(L("vocabulary.empty.title"))
                                .font(
                                    .studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold),
                                )
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(L("vocabulary.empty.subtitle"))
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textSecondary)
                            StudioButton(
                                title: L("vocabulary.action.addFirst"), systemImage: "plus",
                                variant: .secondary,
                            ) {
                                editingVocabularyEntry = nil
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
                                GridItem(.flexible(), spacing: StudioTheme.Spacing.medium),
                            ],
                            alignment: .leading,
                            spacing: StudioTheme.Spacing.medium,
                        ) {
                            ForEach(filteredVocabularyEntries) { entry in
                                vocabularyTermCard(entry)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        subtitle: L("settings.launchAtLogin.subtitle"),
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.launchAtLogin },
                                set: viewModel.setLaunchAtLogin,
                            ),
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.appearance.title"),
                        subtitle: L("settings.appearance.subtitle"),
                    ) {
                        StudioSegmentedPicker(
                            options: AppearanceMode.allCases.map {
                                (label: $0.displayName, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.appearanceMode },
                                set: viewModel.setAppearanceMode,
                            ),
                        )
                        .frame(width: StudioTheme.Layout.appearancePickerWidth)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.language.title"),
                        subtitle: L("settings.language.subtitle"),
                    ) {
                        StudioMenuPicker(
                            options: AppLanguage.allCases.map {
                                (label: $0.displayName, value: $0)
                            },
                            selection: Binding(
                                get: { viewModel.appLanguage },
                                set: viewModel.setAppLanguage,
                            ),
                            width: StudioTheme.Layout.appearancePickerWidth,
                        )
                    }
                }
            }

            StudioSectionTitle(title: L("settings.activationHotkey"))

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                        shortcutConfigurationRow(
                            configuration: ShortcutConfiguration(
                                title: L("settings.shortcuts.activation.title"),
                                subtitle: L("settings.shortcuts.activation.subtitle"),
                                footnote: L("settings.shortcuts.activation.footnote"),
                                icon: "command",
                                badgeSymbol: "mic.fill",
                                binding: viewModel.activationHotkey,
                                isDefault: viewModel.activationHotkey?.signature
                                    == HotkeyBinding.defaultActivation.signature,
                                isThisRecording: recordingTarget == .activation,
                            ),
                            onStartRecording: {
                                recordingTarget = .activation
                                recorder.start { binding in
                                    viewModel.setActivationHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetActivationHotkey()
                            },
                            onUnset: {
                                viewModel.unsetActivationHotkey()
                            },
                        )

                        shortcutConfigurationRow(
                            configuration: ShortcutConfiguration(
                                title: L("settings.shortcuts.ask.title"),
                                subtitle: L("settings.shortcuts.ask.subtitle"),
                                footnote: L("settings.shortcuts.ask.footnote"),
                                icon: "questionmark.bubble.fill",
                                badgeSymbol: "text.quote",
                                binding: viewModel.askHotkey,
                                isDefault: viewModel.askHotkey?.signature
                                    == HotkeyBinding.defaultAsk.signature,
                                isThisRecording: recordingTarget == .ask,
                            ),
                            onStartRecording: {
                                recordingTarget = .ask
                                recorder.start { binding in
                                    viewModel.setAskHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetAskHotkey()
                            },
                            onUnset: {
                                viewModel.unsetAskHotkey()
                            },
                        )

                        shortcutConfigurationRow(
                            configuration: ShortcutConfiguration(
                                title: L("settings.shortcuts.persona.title"),
                                subtitle: L("settings.shortcuts.persona.subtitle"),
                                footnote: L("settings.shortcuts.persona.footnote"),
                                icon: "person.crop.rectangle.stack.fill",
                                badgeSymbol: "person.crop.circle.badge.checkmark",
                                binding: viewModel.personaHotkey,
                                isDefault: viewModel.personaHotkey?.signature
                                    == HotkeyBinding.defaultPersona.signature,
                                isThisRecording: recordingTarget == .persona,
                            ),
                            onStartRecording: {
                                recordingTarget = .persona
                                recorder.start { binding in
                                    viewModel.setPersonaHotkey(binding)
                                    recordingTarget = nil
                                }
                            },
                            onReset: {
                                viewModel.resetPersonaHotkey()
                            },
                            onUnset: {
                                viewModel.unsetPersonaHotkey()
                            },
                        )
                    }

                    if recorder.isRecording {
                        recordingShortcutBanner
                    }
                }

            StudioSectionTitle(title: L("settings.providers"))

            personaProviderSelectionSection

            StudioSectionTitle(title: L("settings.identity"))

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xxLarge) {
                StudioCard {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        StudioSettingRow(
                            title: L("settings.personaDefault.title"),
                            subtitle: L("settings.personaDefault.subtitle")
                        ) {
                            StudioMenuPicker(
                                options: [(label: L("persona.none.title"), value: nil as UUID?)]
                                    + viewModel.personas.map { persona in
                                        (label: persona.name, value: persona.id as UUID?)
                                    },
                                selection: Binding(
                                    get: { viewModel.defaultPersonaSelectionID },
                                    set: { viewModel.setDefaultPersonaSelection($0) },
                                ),
                                width: 200,
                            )
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
                        subtitle: L("settings.microphone.subtitle"),
                    ) {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            StudioMenuPicker(
                                options: [
                                    (
                                        label: L("settings.microphone.automatic"),
                                        value: AudioDeviceManager.automaticDeviceID,
                                    ),
                                ]
                                    + viewModel.availableMicrophones.map {
                                        (label: $0.name, value: $0.id)
                                    },
                                selection: Binding(
                                    get: { viewModel.preferredMicrophoneID },
                                    set: viewModel.setPreferredMicrophoneID,
                                ),
                                width: 260,
                            )

                            StudioButton(
                                title: L("common.refresh"), systemImage: "arrow.clockwise",
                                variant: .secondary,
                            ) {
                                viewModel.refreshAvailableMicrophones()
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.mute.title"),
                        subtitle: L("settings.mute.subtitle"),
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.muteSystemOutputDuringRecording },
                                set: viewModel.setMuteSystemOutputDuringRecording,
                            ),
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
                        subtitle: L("settings.permissionStatus.subtitle"),
                    ) {
                        StudioButton(
                            title: viewModel.isRefreshingPermissions
                                ? L("common.refreshing") : L("common.refresh"),
                            systemImage: "arrow.clockwise",
                            variant: .secondary,
                            isLoading: viewModel.isRefreshingPermissions,
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
                                    StudioTheme.border.opacity(StudioTheme.Opacity.divider),
                                )
                            }
                        }
                    }
                }
            }

            StudioSectionTitle(title: L("settings.other"))

            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("settings.advanced.soundEffects.title"),
                        subtitle: L("settings.advanced.soundEffects.subtitle"),
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.soundEffectsEnabled },
                                set: viewModel.setSoundEffectsEnabled,
                            ),
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.advanced.autoVocabulary.title"),
                        subtitle: L("settings.advanced.autoVocabulary.subtitle"),
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.automaticVocabularyCollectionEnabled },
                                set: viewModel.setAutomaticVocabularyCollectionEnabled,
                            ),
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("settings.advanced.autoUpdate.title"),
                        subtitle: L("settings.advanced.autoUpdate.subtitle"),
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.autoUpdateEnabled },
                                set: viewModel.setAutoUpdateEnabled,
                            ),
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            HStack {
                Spacer()
                StudioButton(
                    title: L("settings.advanced.button"),
                    systemImage: isAdvancedSettingsExpanded ? "chevron.up" : "chevron.down",
                    variant: .ghost,
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isAdvancedSettingsExpanded.toggle()
                    }
                }
                Spacer()
            }

            if isAdvancedSettingsExpanded {
                StudioCard {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                        StudioSettingRow(
                            title: L("settings.advanced.localOptimization.title"),
                            subtitle: L("settings.advanced.localOptimization.subtitle"),
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { viewModel.localOptimizationEnabled },
                                    set: viewModel.setLocalOptimizationEnabled,
                                ),
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                        StudioSettingRow(
                            title: L("settings.advanced.personaHotkeyApply.title"),
                            subtitle: L("settings.advanced.personaHotkeyApply.subtitle"),
                            badge: "Beta",
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { viewModel.personaHotkeyAppliesToSelection },
                                    set: viewModel.setPersonaHotkeyAppliesToSelection,
                                ),
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                        StudioSettingRow(
                            title: L("settings.advanced.agentFramework.title"),
                            subtitle: L("settings.advanced.agentFramework.subtitle"),
                            badge: "Beta",
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { viewModel.agentFrameworkEnabled },
                                    set: viewModel.setAgentFrameworkEnabled,
                                ),
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                        StudioSettingRow(
                            title: L("settings.models.appleFallback"),
                            subtitle: L("settings.models.appleFallback.detail"),
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { viewModel.appleSpeechFallback },
                                    set: viewModel.setAppleSpeechFallback,
                                ),
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Agent Page

    private var agentPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioSegmentedPicker(
                options: AgentConfigurationTab.allCases.map { (label: $0.title, value: $0) },
                selection: $agentConfigurationTab,
            )

            switch agentConfigurationTab {
            case .general:
                agentGeneralTabContent
            case .mcpServers:
                agentMCPServersTabContent
            }
        }
    }

    private var agentGeneralTabContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                StudioSettingRow(
                    title: L("agent.general.enabled.title"),
                    subtitle: L("agent.general.enabled.subtitle"),
                ) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.agentEnabled },
                        set: viewModel.setAgentEnabled,
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private var agentMCPServersTabContent: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
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
                variant: .secondary,
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
                        isLoading: viewModel.isTestingMCPServer(server.id),
                    ) {
                        viewModel.testMCPConnection(for: server)
                    }

                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { viewModel.updateMCPServerEnabled(id: server.id, enabled: $0) },
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
                        text: $viewModel.mcpDraftName,
                    )

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        Text(L("agent.mcp.transportType"))
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)

                        StudioSegmentedPicker(
                            options: [
                                (label: "STDIO", value: MCPTransportType.stdio),
                                (label: "HTTP/SSE", value: MCPTransportType.http),
                            ],
                            selection: $viewModel.mcpDraftTransportType,
                        )
                    }

                    if viewModel.mcpDraftTransportType == .stdio {
                        StudioTextInputCard(
                            label: L("agent.mcp.stdio.command"),
                            placeholder: "/usr/local/bin/my-mcp-server",
                            text: $viewModel.mcpDraftStdioCommand,
                        )
                        StudioTextInputCard(
                            label: L("agent.mcp.stdio.args"),
                            placeholder: "--port 3000 --verbose",
                            text: $viewModel.mcpDraftStdioArgs,
                        )
                        mcpKeyValueEditor(
                            label: L("agent.mcp.stdio.env"),
                            hint: L("agent.mcp.stdio.envHint"),
                            text: $viewModel.mcpDraftStdioEnv,
                        )
                    } else {
                        StudioTextInputCard(
                            label: L("agent.mcp.http.url"),
                            placeholder: "https://mcp.example.com/sse",
                            text: $viewModel.mcpDraftHTTPURL,
                        )
                        mcpKeyValueEditor(
                            label: L("agent.mcp.http.headers"),
                            hint: L("agent.mcp.http.headersHint"),
                            text: $viewModel.mcpDraftHTTPHeaders,
                        )
                    }
                }
            }

            StudioCard(padding: StudioTheme.Insets.cardDense) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                    StudioSettingRow(
                        title: L("agent.mcp.enabled.title"),
                        subtitle: L("agent.mcp.enabled.subtitle"),
                    ) {
                        Toggle("", isOn: $viewModel.mcpDraftEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

                    StudioSettingRow(
                        title: L("agent.mcp.autoConnect.title"),
                        subtitle: L("agent.mcp.autoConnect.subtitle"),
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
                    isLoading: viewModel.mcpConnectionTestState == .testing,
                ) {
                    viewModel.testMCPDraftConnection()
                }
                StudioButton(
                    title: L("common.save"),
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: !viewModel.canSaveMCPDraft,
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
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
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
        case let .success(tools):
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
                            .fill(StudioTheme.surfaceMuted),
                    )
                }
            }
        case let .failure(message):
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
        case .stdio: "STDIO"
        case .http: "HTTP/SSE"
        }
    }

    private func mcpTransportDetail(for server: MCPServerConfig) -> String {
        switch server.transport {
        case let .stdio(config): config.command
        case let .http(config): config.url
        }
    }

    private func shortcutConfigurationRow(
        configuration: ShortcutConfiguration,
        onStartRecording: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onUnset: @escaping () -> Void,
    ) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [StudioTheme.accentSoft, StudioTheme.surfaceMuted],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                )
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: configuration.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent),
                )

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(configuration.title)
                    .font(.studioDisplay(StudioTheme.Typography.cardTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(configuration.subtitle)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(configuration.footnote)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)

            Spacer(minLength: StudioTheme.Spacing.large)

            shortcutPill(configuration.binding, accentSymbol: configuration.badgeSymbol)
                .frame(minWidth: 170, alignment: .leading)

            shortcutActionButtons(
                isDefault: configuration.isDefault,
                isUnset: configuration.binding == nil,
                isThisRecording: configuration.isThisRecording,
                onStart: onStartRecording,
                onReset: onReset,
                onUnset: onUnset,
            )
        }
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(0.42)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin,
                ),
        )
    }

    private var recordingShortcutBanner: some View {
        HStack(spacing: StudioTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(StudioTheme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "keyboard")
                        .foregroundStyle(StudioTheme.accent),
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
                .fill(StudioTheme.accentSoft.opacity(0.72)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(StudioTheme.accent.opacity(0.28), lineWidth: StudioTheme.BorderWidth.thin),
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
                    .fill(StudioTheme.surface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                    .stroke(
                        StudioTheme.border.opacity(0.75), lineWidth: StudioTheme.BorderWidth.thin,
                    ),
            )
    }

    private var recordingBannerDescription: String {
        switch recordingTarget {
        case .activation:
            L("settings.shortcuts.recordingActivation")
        case .ask:
            L("settings.shortcuts.recordingAsk")
        case .persona:
            L("settings.shortcuts.recordingPersona")
        case nil:
            L("settings.shortcuts.recordingGeneric")
        }
    }

    private func shortcutActionButtons(
        isDefault: Bool,
        isUnset: Bool,
        isThisRecording: Bool,
        onStart: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onUnset: @escaping () -> Void,
    ) -> some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            StudioIconButton(
                systemImage: isThisRecording ? "stop.circle.fill" : "keyboard",
                variant: isThisRecording ? .secondary : .primary,
            ) {
                if isThisRecording {
                    recorder.stop()
                    recordingTarget = nil
                } else {
                    onStart()
                }
            }
            .studioTooltip(
                isThisRecording ? L("settings.shortcuts.stopRecording") : L("settings.shortcuts.record"),
                yOffset: 38,
            )

            StudioIconButton(
                systemImage: "arrow.counterclockwise",
                variant: .secondary,
                isDisabled: isDefault,
            ) {
                onReset()
            }
            .studioTooltip(L("common.reset"), yOffset: 38)

            StudioIconButton(
                systemImage: "xmark.circle",
                variant: .secondary,
                isDisabled: isUnset,
            ) {
                onUnset()
            }
            .studioTooltip(L("settings.shortcuts.unset"), yOffset: 38)
        }
    }

    @ViewBuilder
    private func shortcutPill(_ binding: HotkeyBinding?, accentSymbol _: String) -> some View {
        if let binding {
            HStack(spacing: StudioTheme.Spacing.xxxSmall) {
                ForEach(HotkeyFormat.components(binding), id: \.self) { key in
                    shortcutKeycap(key)
                }
            }
        } else {
            shortcutKeycap(L("settings.shortcuts.none"))
                .opacity(0.5)
        }
    }

    private func personaSelectionCard(
        title: String,
        subtitle: String,
        initials: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
                HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.large, style: .continuous,
                    )
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Group {
                            if let systemImage {
                                Image(systemName: systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(
                                        isSelected ? StudioTheme.accent : StudioTheme.textSecondary,
                                    )
                            } else {
                                Text(initials)
                                    .font(
                                        .studioBody(StudioTheme.Typography.caption, weight: .bold),
                                    )
                                    .foregroundStyle(
                                        isSelected ? StudioTheme.accent : StudioTheme.textSecondary,
                                    )
                            }
                        },
                    )

                    Spacer()

                    Circle()
                        .stroke(
                            isSelected ? StudioTheme.accent : StudioTheme.border,
                            lineWidth: StudioTheme.BorderWidth.emphasis,
                        )
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .fill(isSelected ? StudioTheme.accent : Color.clear)
                                .frame(width: 8, height: 8),
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
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            .padding(StudioTheme.Insets.cardCompact)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .fill(
                        isSelected
                            ? StudioTheme.accentSoft.opacity(0.75)
                            : StudioTheme.surfaceMuted.opacity(0.42),
                    ),
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isSelected
                            ? StudioTheme.accent.opacity(0.45)
                            : StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: isSelected
                            ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin,
                    ),
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
                            ? "checkmark.circle.fill" : "exclamationmark.circle",
                    )
                    .foregroundStyle(
                        permission.isGranted ? StudioTheme.success : StudioTheme.warning,
                    )

                    Text(permission.title)
                        .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    StudioPill(
                        title: permission.badgeText,
                        tone: permission.isGranted ? StudioTheme.success : StudioTheme.warning,
                        fill: (permission.isGranted ? StudioTheme.success : StudioTheme.warning)
                            .opacity(0.12),
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
                variant: permission.isGranted ? .secondary : .primary,
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
                            ? StudioTheme.textPrimary : StudioTheme.textTertiary,
                    )
            }
            .foregroundStyle(
                vocabularyFilter == filter ? StudioTheme.textPrimary : StudioTheme.textSecondary,
            )
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical + 2)
            .background(
                Capsule()
                    .fill(
                        vocabularyFilter == filter
                            ? StudioTheme.surface : StudioTheme.surfaceMuted.opacity(0.82),
                    ),
            )
            .overlay(
                Capsule()
                    .stroke(
                        StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: StudioTheme.BorderWidth.thin,
                    ),
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func vocabularyTermCard(_ entry: VocabularyEntry) -> some View {
        VocabularyTermCard(
            entry: entry,
            onCopy: {
                viewModel.copyVocabularyTerm(entry.term)
            },
            onEdit: {
                editingVocabularyEntry = entry
                newVocabularyTerm = entry.term
                isAddingVocabulary = false
            },
            onDelete: {
                viewModel.removeVocabularyEntry(id: entry.id)
            },
        )
    }

    private var vocabularyAddSheet: some View {
        let isEditing = editingVocabularyEntry != nil

        return VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            Text(L(isEditing ? "vocabulary.sheet.editTitle" : "vocabulary.sheet.title"))
                .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(L(isEditing ? "vocabulary.sheet.editSubtitle" : "vocabulary.sheet.subtitle"))
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
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous,
                    )
                    .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill)),
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous,
                    )
                    .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
                )
                .onSubmit {
                    submitVocabularyTerm()
                }

            HStack {
                Spacer()
                StudioButton(title: L("common.cancel"), systemImage: nil, variant: .secondary) {
                    editingVocabularyEntry = nil
                    newVocabularyTerm = ""
                    isAddingVocabulary = false
                }
                StudioButton(
                    title: L(isEditing ? "common.save" : "vocabulary.action.addWord"),
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
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

        if let editingVocabularyEntry {
            viewModel.updateVocabularyEntry(id: editingVocabularyEntry.id, term: term)
        } else {
            viewModel.addVocabularyTerm(term)
        }

        editingVocabularyEntry = nil
        newVocabularyTerm = ""
        isAddingVocabulary = false
    }

    private func vocabularyCount(for filter: VocabularyFilter) -> Int {
        guard let source = filter.source else { return viewModel.vocabularyEntries.count }
        return viewModel.vocabularyEntries.count(where: { $0.source == source })
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
        OpenAIAudioModelCatalog.suggestedWhisperModels(forEndpoint: viewModel.whisperBaseURL)
    }

    private func llmEndpointSuggestions(for provider: LLMRemoteProvider?) -> [String] {
        guard let provider else {
            return uniqueSuggestions([viewModel.llmBaseURL])
        }

        return uniqueSuggestions(
            [viewModel.llmBaseURL, provider.defaultBaseURL] + provider.endpointPresets.map(\.url),
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
                            width: 320,
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
                        secure: true,
                    ) {
                        if let url = llmProviderAPIKeyURL(provider) {
                            apiKeyHelpButton(url: url)
                        }
                    }

                    StudioSuggestedTextInputCard(
                        label: L("settings.models.apiEndpoint"),
                        placeholder: provider.defaultBaseURL.isEmpty
                            ? "https://api.openai.com/v1" : provider.defaultBaseURL,
                        text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                        suggestions: llmEndpointSuggestions(for: provider),
                    )

                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: provider.defaultModel,
                        text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                        suggestions: remoteLLMModelSuggestions,
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
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL,
                    ),
                    suggestions: whisperEndpointSuggestions,
                )
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.model"),
                    placeholder: whisperModelSuggestions[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions,
                )
            } else {
                if viewModel.llmProvider == .ollama {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.ollama.baseURL"),
                        placeholder: "http://127.0.0.1:11434",
                        text: Binding(
                            get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL,
                        ),
                        suggestions: ollamaEndpointSuggestions,
                    )
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.localModel"),
                        placeholder: "qwen2.5:7b",
                        text: Binding(
                            get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel,
                        ),
                        suggestions: ollamaModelSuggestions,
                    )
                    Toggle(
                        L("settings.models.ollama.autoSetup"),
                        isOn: Binding(
                            get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup,
                        ),
                    )
                    .toggleStyle(.switch)
                } else {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.remote.baseURL"),
                        placeholder: "https://api.openai.com/v1",
                        text: Binding(get: { viewModel.llmBaseURL }, set: viewModel.setLLMBaseURL),
                        suggestions: llmEndpointSuggestions(for: focusedLLMRemoteProvider),
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: "gpt-4o-mini",
                        text: Binding(get: { viewModel.llmModel }, set: viewModel.setLLMModel),
                        suggestions: llmModelSuggestions,
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(get: { viewModel.llmAPIKey }, set: viewModel.setLLMAPIKey),
                        secure: true,
                    )
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
                        endPoint: .trailing,
                    ),
                ),
        )
    }

    private func historyTable(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            VStack(spacing: StudioTheme.Spacing.none) {
                HStack {
                    Text(L("history.table.timestamp"))
                        .frame(
                            width: StudioTheme.Layout.historyTimestampColumnWidth,
                            alignment: .leading,
                        )
                    Text(L("history.table.sourceFile"))
                        .frame(
                            width: StudioTheme.Layout.historySourceColumnWidth, alignment: .leading,
                        )
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
                            onCopyResult: {
                                viewModel.copyHistoryResult(id: record.id)
                            },
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
                            },
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
                                    cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous,
                                )
                                .fill(StudioTheme.surfaceMuted)
                                .frame(
                                    width: StudioTheme.ControlSize.overviewBadge,
                                    height: StudioTheme.ControlSize.overviewBadge,
                                )
                                .overlay(
                                    Image(systemName: "waveform.and.magnifyingglass")
                                        .font(
                                            .system(
                                                size: StudioTheme.Typography.iconSmall,
                                                weight: .semibold,
                                            ),
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary),
                                )
                                Text(L("home.activity.title"))
                                    .font(
                                        .studioBody(StudioTheme.Typography.bodySmall, weight: .semibold),
                                    )
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }

                            Text("\(viewModel.statsCompletionRate)%")
                                .font(
                                    .studioDisplay(StudioTheme.Typography.displayLarge, weight: .bold),
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
                                lineWidth: StudioTheme.BorderWidth.overviewDonut,
                            )
                            .frame(
                                width: StudioTheme.Layout.overviewDonutSize,
                                height: StudioTheme.Layout.overviewDonutSize,
                            )
                            .overlay(
                                Circle()
                                    .trim(from: 0, to: CGFloat(viewModel.statsCompletionRate) / 100)
                                    .stroke(
                                        StudioTheme.accent.opacity(
                                            StudioTheme.Opacity.overviewProgress,
                                        ),
                                        style: StrokeStyle(
                                            lineWidth: StudioTheme.BorderWidth.overviewDonut,
                                            lineCap: .round,
                                        ),
                                    )
                                    .rotationEffect(.degrees(StudioTheme.Angles.overviewProgressStart)),
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
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous),
            )

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
                            size: CGSize(width: cardWidth, height: cardHeight),
                        )
                        homeMiniMetric(
                            icon: "mic",
                            value: "\(viewModel.statsTotalCharacters)",
                            title: L("home.metric.charactersDictated"),
                            size: CGSize(width: cardWidth, height: cardHeight),
                        )
                    }

                    HStack(spacing: spacing) {
                        homeMiniMetric(
                            icon: "hourglass",
                            value: "\(viewModel.statsSavedMinutes) min",
                            title: L("home.metric.timeSaved"),
                            size: CGSize(width: cardWidth, height: cardHeight),
                        )
                        homeMiniMetric(
                            icon: "bolt",
                            value: viewModel.statsAveragePaceWPM > 0
                                ? "\(viewModel.statsAveragePaceWPM) wpm" : "--",
                            title: L("home.metric.averagePace"),
                            size: CGSize(width: cardWidth, height: cardHeight),
                        )
                    }
                }
            }
            .frame(
                minWidth: StudioTheme.Layout.overviewSideMetricsWidth,
                maxWidth: .infinity,
                minHeight: StudioTheme.Layout.overviewPrimaryMinHeight,
                maxHeight: StudioTheme.Layout.overviewPrimaryMinHeight,
                alignment: .top,
            )
        }
    }

    private func homeMiniMetric(icon: String, value: String, title: String, size: CGSize)
        -> some View
    {
        StudioCard(padding: StudioTheme.Insets.cardCompact) {
            VStack(alignment: .center, spacing: StudioTheme.Spacing.smallMedium) {
                RoundedRectangle(
                    cornerRadius: StudioTheme.CornerRadius.miniMetricIcon, style: .continuous,
                )
                .fill(StudioTheme.surfaceMuted)
                .frame(
                    width: StudioTheme.ControlSize.overviewMiniIcon,
                    height: StudioTheme.ControlSize.overviewMiniIcon,
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary),
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
        primaryAction: @escaping () -> Void,
    ) -> some View {
        HStack {
            Text(title)
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            StudioButton(
                title: secondaryButtonTitle, systemImage: nil, variant: .secondary,
                action: secondaryAction,
            )
            StudioButton(
                title: primaryButtonTitle, systemImage: nil, variant: .primary,
                action: primaryAction,
            )
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
                            onCopyResult: {
                                viewModel.copyHistoryResult(id: record.id)
                            },
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
                            },
                        )
                        if record.id != records.last?.id {
                            Divider().overlay(
                                StudioTheme.border.opacity(StudioTheme.Opacity.listDivider),
                            )
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
                    variant: card.isSelected ? .secondary : .primary,
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
            viewModel.sttProvider == .appleSpeech || viewModel.sttProvider == .localModel
        case .llm:
            viewModel.llmProvider == .ollama
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
                    height: StudioTheme.ControlSize.architectureBadge,
                )
                .overlay(
                    Image(systemName: title.contains("Local") ? "cpu.fill" : "cloud.fill")
                        .foregroundStyle(isActive ? StudioTheme.accent : StudioTheme.textSecondary),
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
                    lineWidth: StudioTheme.BorderWidth.emphasis,
                )
                .frame(
                    width: StudioTheme.ControlSize.selectionIndicator,
                    height: StudioTheme.ControlSize.selectionIndicator,
                )
                .overlay(
                    Circle()
                        .fill(isActive ? StudioTheme.accent : Color.clear)
                        .frame(
                            width: StudioTheme.ControlSize.selectionIndicatorInner,
                            height: StudioTheme.ControlSize.selectionIndicatorInner,
                        ),
                )
        }
        .padding(StudioTheme.Insets.cardCompact)
        .background(
            RoundedRectangle(
                cornerRadius: StudioTheme.CornerRadius.architectureOption, style: .continuous,
            )
            .fill(isActive ? StudioTheme.surface : StudioTheme.surfaceMuted),
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
                    ? OpenAIAudioModelCatalog.defaultWhisperModel(
                        forEndpoint: viewModel.whisperBaseURL,
                    ) : viewModel.whisperModel,
            )
        case StudioModelProviderID.typefluxOfficial.rawValue:
            viewModel.setSTTProvider(.typefluxOfficial)
        case StudioModelProviderID.googleCloud.rawValue:
            viewModel.setSTTProvider(.googleCloud)
        case StudioModelProviderID.typefluxCloud.rawValue:
            viewModel.setLLMRemoteProvider(.typefluxCloud)
        case "ollama-local":
            viewModel.setLLMModelSelection(
                .ollama,
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel,
            )
        default:
            if let providerID = StudioModelProviderID(rawValue: card.id),
               let provider = LLMRemoteProvider.from(providerID: providerID)
            {
                viewModel.setLLMRemoteProvider(provider)
            }
        }
    }

    private var activeModelProviderID: StudioModelProviderID {
        switch viewModel.modelDomain {
        case .stt:
            switch viewModel.sttProvider {
            case .freeModel:
                .freeSTT
            case .appleSpeech:
                .appleSpeech
            case .localModel:
                .localSTT
            case .whisperAPI:
                .whisperAPI
            case .multimodalLLM:
                .multimodalLLM
            case .aliCloud:
                .aliCloud
        case .doubaoRealtime:
            .doubaoRealtime
        case .googleCloud:
            .googleCloud
        case .groq:
            .groqSTT
            case .typefluxOfficial:
                .typefluxOfficial
            }
        case .llm:
            viewModel.llmProvider == .ollama
                ? .ollama : viewModel.llmRemoteProvider.studioProviderID
        }
    }

    private var modelProviderCards: [StudioModelCard] {
        switch viewModel.modelDomain {
        case .stt:
            [
                StudioModelCard(
                    id: StudioModelProviderID.typefluxOfficial.rawValue,
                    name: STTProvider.typefluxOfficial.displayName,
                    summary: L("settings.models.card.typefluxOfficial.summary"),
                    badge: L("settings.models.badge.official"),
                    metadata: L("settings.models.builtInDefaultModel"),
                    isSelected: viewModel.sttProvider == .typefluxOfficial,
                    isMuted: false,
                    actionTitle: L("settings.models.useTypefluxOfficial"),
                ),
            ] + (FreeSTTModelRegistry.suggestedModelNames.isEmpty ? [] : [
                StudioModelCard(
                    id: StudioModelProviderID.freeSTT.rawValue,
                    name: STTProvider.freeModel.displayName,
                    summary: L("settings.models.card.freeSTT.summary"),
                    badge: L("settings.models.badge.free"),
                    metadata: viewModel.freeSTTModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.freeSTTModel,
                    isSelected: viewModel.sttProvider == .freeModel,
                    isMuted: false,
                    actionTitle: L("settings.models.useRemote"),
                ),
            ]) + [
                StudioModelCard(
                    id: StudioModelProviderID.localSTT.rawValue,
                    name: L("settings.models.localModels"),
                    summary: L("settings.models.card.localSTT.summary"),
                    badge: L("settings.models.badge.local"),
                    metadata: viewModel.localSTTModel.displayName,
                    isSelected: viewModel.sttProvider == .localModel,
                    isMuted: false,
                    actionTitle: L("settings.models.useLocal"),
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
                    actionTitle: L("settings.models.useRemote"),
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
                    actionTitle: L("settings.models.useMultimodal"),
                ),
                StudioModelCard(
                    id: StudioModelProviderID.aliCloud.rawValue,
                    name: STTProvider.aliCloud.displayName,
                    summary: L("settings.models.card.aliCloud.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.builtInDefaultModel"),
                    isSelected: viewModel.sttProvider == .aliCloud,
                    isMuted: false,
                    actionTitle: L("settings.models.useAliCloud"),
                ),
                StudioModelCard(
                    id: StudioModelProviderID.doubaoRealtime.rawValue,
                    name: STTProvider.doubaoRealtime.displayName,
                    summary: L("settings.models.card.doubao.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.builtInDefaultProfile"),
                    isSelected: viewModel.sttProvider == .doubaoRealtime,
                    isMuted: false,
                    actionTitle: L("settings.models.useDoubao"),
                ),
                StudioModelCard(
                    id: StudioModelProviderID.googleCloud.rawValue,
                    name: STTProvider.googleCloud.displayName,
                    summary: L("settings.models.card.googleCloud.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.googleCloud.streaming"),
                    isSelected: viewModel.sttProvider == .googleCloud,
                    isMuted: false,
                    actionTitle: L("settings.models.useGoogleCloud"),
                ),
                StudioModelCard(
                    id: StudioModelProviderID.groqSTT.rawValue,
                    name: STTProvider.groq.displayName,
                    summary: L("settings.models.card.groq.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.groqSTTModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.groqSTTModel,
                    isSelected: viewModel.sttProvider == .groq,
                    isMuted: false,
                    actionTitle: L("settings.models.useGroq"),
                ),
            ]
        case .llm:
            [
                StudioModelCard(
                    id: LLMRemoteProvider.typefluxCloud.studioProviderID.rawValue,
                    name: LLMRemoteProvider.typefluxCloud.displayName,
                    summary: L("settings.models.card.typefluxCloud.summary"),
                    badge: L("settings.models.badge.official"),
                    metadata: L("settings.models.builtInDefaultModel"),
                    isSelected: viewModel.llmProvider == .openAICompatible
                        && viewModel.llmRemoteProvider == .typefluxCloud,
                    isMuted: false,
                    actionTitle: L("settings.models.useTypefluxCloud"),
                ),
            ] + (FreeLLMModelRegistry.suggestedModelNames.isEmpty ? [] : [
                StudioModelCard(
                    id: LLMRemoteProvider.freeModel.studioProviderID.rawValue,
                    name: LLMRemoteProvider.freeModel.displayName,
                    summary: L("settings.models.card.\(LLMRemoteProvider.freeModel.rawValue).summary"),
                    badge: L("settings.models.badge.free"),
                    metadata: metadata(for: .freeModel),
                    isSelected: viewModel.llmProvider == .openAICompatible
                        && viewModel.llmRemoteProvider == .freeModel,
                    isMuted: false,
                    actionTitle: L("settings.models.useRemote"),
                ),
            ]) + [
                StudioModelCard(
                    id: StudioModelProviderID.ollama.rawValue,
                    name: LLMProvider.ollama.displayName,
                    summary: L("settings.models.card.ollama.summary"),
                    badge: L("settings.models.badge.local"),
                    metadata: viewModel.ollamaModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.ollamaModel,
                    isSelected: viewModel.llmProvider == .ollama,
                    isMuted: false,
                    actionTitle: L("settings.models.useLocal"),
                ),
            ] + LLMRemoteProvider.settingsDisplayOrder
                .filter { $0 != .freeModel && $0 != .typefluxCloud }
                .map { provider in
                    StudioModelCard(
                        id: provider.studioProviderID.rawValue,
                        name: provider.displayName,
                        summary: L("settings.models.card.\(provider.rawValue).summary"),
                        badge: provider.apiStyle == .openAICompatible
                            ? L("settings.models.badge.api") : L("settings.models.badge.native"),
                        metadata: metadata(for: provider),
                        isSelected: viewModel.llmProvider == .openAICompatible
                            && viewModel.llmRemoteProvider == provider,
                        isMuted: false,
                        actionTitle: L("settings.models.useRemote"),
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
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous,
                        )
                        .fill(StudioTheme.accentSoft)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(
                                systemName: viewModel.modelDomain == .stt
                                    ? "waveform.and.mic" : "sparkles.rectangle.stack",
                            )
                            .foregroundStyle(StudioTheme.accent),
                        )

                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(modelOverviewTitle)
                                .font(
                                    .studioDisplay(
                                        StudioTheme.Typography.sectionTitle, weight: .semibold,
                                    ),
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
                            fill: modelOverviewModeFill,
                        )
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
                        variant: .secondary,
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
                                        StudioTheme.Typography.sectionTitle, weight: .semibold,
                                    ),
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
                                fill: StudioTheme.success.opacity(0.12),
                            )
                        } else {
                            StudioButton(
                                title: L("settings.models.useAsDefault"),
                                systemImage: "checkmark.circle.fill", variant: .secondary,
                            ) {
                                applyFocusedProviderAsDefault()
                            }
                        }
                    }
                }

                focusedProviderForm

                if [
                    StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .ollama, .aliCloud,
                    .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial,
                ].contains(viewModel.focusedModelProvider) || focusedLLMRemoteProvider != nil {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        Spacer()

                        if shouldShowFocusedLLMConnectionTestButton {
                            StudioButton(
                                title: viewModel.llmConnectionTestState == .testing
                                    ? L("settings.models.testingConnection") : L("common.test"),
                                systemImage: viewModel.llmConnectionTestState == .testing
                                    ? nil : "network",
                                variant: .secondary,
                                isDisabled: viewModel.llmConnectionTestState == .testing,
                                isLoading: viewModel.llmConnectionTestState == .testing,
                            ) {
                                viewModel.testLLMConnection()
                            }
                        } else if [
                            StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .aliCloud,
                            .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial,
                        ].contains(viewModel.focusedModelProvider),
                            !viewModel.focusedModelProvider.requiresLoginForConnectionTest || authState.isLoggedIn
                        {
                            StudioButton(
                                title: viewModel.sttConnectionTestState == .testing
                                    ? L("settings.models.testingConnection") : L("common.test"),
                                systemImage: viewModel.sttConnectionTestState == .testing
                                    ? nil : "network",
                                variant: .secondary,
                                isDisabled: viewModel.sttConnectionTestState == .testing,
                                isLoading: viewModel.sttConnectionTestState == .testing,
                            ) {
                                viewModel.testSTTConnection()
                            }
                        }

                        if viewModel.focusedModelProvider.showsManualSaveButton {
                            StudioButton(
                                title: L("common.save"), systemImage: "checkmark", variant: .primary,
                            ) {
                                viewModel.applyModelConfiguration()
                            }
                        }
                    }

                    if shouldShowFocusedLLMConnectionTestButton {
                        connectionTestResultView(viewModel.llmConnectionTestState)
                    } else if [
                        StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .aliCloud,
                        .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial,
                    ].contains(viewModel.focusedModelProvider),
                        !viewModel.focusedModelProvider.requiresLoginForConnectionTest || authState.isLoggedIn
                    {
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
                            variant: .primary,
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
                                variant: .primary,
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
                                    .studioBody(StudioTheme.Typography.caption, weight: .semibold),
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
                                            StudioTheme.Typography.caption, weight: .semibold,
                                        ),
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
                                                weight: .semibold,
                                            ),
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: StudioTheme.CornerRadius.medium,
                                                style: .continuous,
                                            )
                                            .fill(StudioTheme.surfaceMuted),
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
                                                weight: .semibold,
                                            ),
                                        )
                                        .foregroundStyle(StudioTheme.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: StudioTheme.CornerRadius.medium,
                                                style: .continuous,
                                            )
                                            .fill(StudioTheme.surfaceMuted),
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

    private var focusedProviderForm: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
            switch viewModel.focusedModelProvider {
            case .typefluxOfficial:
                typefluxOfficialProviderForm

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
                                set: viewModel.setFreeSTTModel,
                            ),
                            width: 320,
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

                    ForEach(LocalSTTModel.displayOrder, id: \.self) { model in
                        localSTTModelOptionCard(model)
                    }
                }
                .confirmationDialog(
                    localSTTPendingRedownload.map {
                        L("settings.models.redownloadDialog.title", $0.displayName)
                    } ?? "",
                    isPresented: Binding(
                        get: { localSTTPendingRedownload != nil },
                        set: { if !$0 { localSTTPendingRedownload = nil } },
                    ),
                    titleVisibility: .visible,
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
                        set: { if !$0 { localSTTPendingDelete = nil } },
                    ),
                    titleVisibility: .visible,
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
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL,
                    ),
                    suggestions: whisperEndpointSuggestions,
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: whisperModelSuggestions[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions,
                )
                StudioTextInputCard(
                    label: L("common.apiKey"), placeholder: "sk-...",
                    text: Binding(
                        get: { viewModel.whisperAPIKey }, set: viewModel.setWhisperAPIKey,
                    ),
                    secure: true,
                ) {
                    if let url = sttProviderAPIKeyURL(.whisperAPI) {
                        apiKeyHelpButton(url: url)
                    }
                }

            case .ollama:
                StudioSuggestedTextInputCard(
                    label: L("settings.models.ollama.baseURL"),
                    placeholder: "http://127.0.0.1:11434",
                    text: Binding(
                        get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL,
                    ),
                    suggestions: ollamaEndpointSuggestions,
                )
                StudioSuggestedTextInputCard(
                    label: L("settings.models.localModel"),
                    placeholder: "qwen2.5:7b",
                    text: Binding(get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel),
                    suggestions: ollamaModelSuggestions,
                )
                Toggle(
                    L("settings.models.ollama.autoInstall"),
                    isOn: Binding(
                        get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup,
                    ),
                )
                .toggleStyle(.switch)

            case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek,
                 .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
                llmRemoteProviderForm

            case .typefluxCloud:
                typefluxCloudLLMProviderForm

            case .multimodalLLM:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.apiEndpoint"),
                        placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMBaseURL },
                            set: viewModel.setMultimodalLLMBaseURL,
                        ),
                        suggestions: multimodalEndpointSuggestions,
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMModel },
                            set: viewModel.setMultimodalLLMModel,
                        ),
                        suggestions: multimodalModelSuggestions,
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.multimodalLLMAPIKey },
                            set: viewModel.setMultimodalLLMAPIKey,
                        ), secure: true,
                    ) {
                        if let url = sttProviderAPIKeyURL(.multimodalLLM) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                    Text(L("settings.models.multimodalLLM.audioHint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

            case .aliCloud:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.aliCloudAPIKey }, set: viewModel.setAliCloudAPIKey,
                        ),
                        secure: true,
                    ) {
                        if let url = sttProviderAPIKeyURL(.aliCloud) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                }

            case .doubaoRealtime:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("settings.models.doubao.appID"), placeholder: "APPID",
                        text: Binding(get: { viewModel.doubaoAppID }, set: viewModel.setDoubaoAppID),
                    )
                    StudioTextInputCard(
                        label: L("settings.models.doubao.accessToken"), placeholder: "access-token",
                        text: Binding(
                            get: { viewModel.doubaoAccessToken },
                            set: viewModel.setDoubaoAccessToken,
                        ), secure: true,
                    ) {
                        Button {
                            NSWorkspace.shared.open(
                                URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!,
                            )
                        } label: {
                            Text(L("settings.models.doubao.docs"))
                                .font(.studioBody(StudioTheme.Typography.caption))
                                .foregroundStyle(StudioTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

            case .googleCloud:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("settings.models.googleCloud.projectID"), placeholder: "my-gcp-project",
                        text: Binding(
                            get: { viewModel.googleCloudProjectID },
                            set: viewModel.setGoogleCloudProjectID,
                        ),
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "AIza...",
                        text: Binding(
                            get: { viewModel.googleCloudAPIKey },
                            set: viewModel.setGoogleCloudAPIKey,
                        ),
                        secure: true,
                    ) {
                        if let url = sttProviderAPIKeyURL(.googleCloud) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: GoogleCloudSpeechDefaults.model,
                        text: Binding(
                            get: { viewModel.googleCloudModel },
                            set: viewModel.setGoogleCloudModel,
                        ),
                        suggestions: GoogleCloudSpeechDefaults.suggestedModels,
                    )
                    Text(L("settings.models.googleCloud.directHint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Link(destination: GoogleCloudSpeechDefaults.apiDocumentationURL) {
                        Text(L("settings.models.googleCloud.docs"))
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                            .foregroundStyle(StudioTheme.accent)
                    }
                    .buttonStyle(.plain)
                }

            case .groqSTT:
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "gsk_...",
                        text: Binding(get: { viewModel.groqSTTAPIKey }, set: viewModel.setGroqSTTAPIKey),
                        secure: true,
                    ) {
                        if let url = sttProviderAPIKeyURL(.groq) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: OpenAIAudioModelCatalog.groqWhisperModels[0],
                        text: Binding(get: { viewModel.groqSTTModel }, set: viewModel.setGroqSTTModel),
                        suggestions: OpenAIAudioModelCatalog.groqWhisperModels,
                    )
                }
            }
        }
    }

    private var shouldShowFocusedLLMConnectionTestButton: Bool {
        guard viewModel.focusedModelProvider.domain == .llm else { return false }
        guard viewModel.focusedModelProvider == .ollama || focusedLLMRemoteProvider != nil else {
            return false
        }

        return !viewModel.focusedModelProvider.requiresLoginForConnectionTest || authState.isLoggedIn
    }

    @ViewBuilder
    private var typefluxOfficialProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxOfficial.loginRequired"))
    }

    @ViewBuilder
    private var typefluxCloudLLMProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxCloud.loginRequired"))
    }

    @ViewBuilder
    private func typefluxLoginRequiredForm(message: String) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            if !authState.isLoggedIn {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    Text(message)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.warning)

                    HStack {
                        Spacer()

                        StudioButton(
                            title: L("settings.models.typefluxOfficial.signIn"),
                            systemImage: "person.circle",
                            variant: .primary,
                        ) {
                            LoginWindowController.shared.show()
                        }
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
        case let .success(firstMs, totalMs, preview):
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
                                cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous,
                            )
                            .fill(StudioTheme.surfaceMuted),
                        )
                }
            }
        case let .failure(message):
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
                        variant: .primary,
                    ) {
                        viewModel.applyModelConfiguration()
                    }
                    if viewModel.modelDomain == .llm, viewModel.llmProvider == .ollama {
                        StudioButton(
                            title: L("settings.models.prepareOllama"), systemImage: nil,
                            variant: .secondary,
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
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous,
                        )
                        .fill(providerBadgeBackground(for: providerID, isFocused: isFocused))
                        .frame(
                            width: StudioTheme.ControlSize.modelProviderBadge,
                            height: StudioTheme.ControlSize.modelProviderBadge,
                        )
                        .overlay(
                            providerIconView(for: providerID, isFocused: isFocused),
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
                                height: StudioTheme.ControlSize.modelProviderStatusDot,
                            )
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
                                fill: StudioTheme.success.opacity(0.12),
                            )
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isFocused ? StudioTheme.accent.opacity(0.62) : Color.clear,
                        lineWidth: StudioTheme.BorderWidth.emphasis,
                    ),
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
        if provider.usesTypefluxBranding {
            return isFocused ? Color.white.opacity(0.06) : Color.clear
        }

        if providerLogoResourceName(for: provider) != nil {
            return isFocused ? Color.white.opacity(0.98) : Color.white.opacity(0.92)
        }

        return isFocused ? StudioTheme.accentSoft : StudioTheme.surfaceMuted
    }

    @ViewBuilder
    private func providerIconView(for provider: StudioModelProviderID, isFocused: Bool) -> some View {
        if provider.usesTypefluxBranding {
            TypefluxLogoBadge(
                size: 28,
                symbolSize: 14,
                backgroundShape: .circle,
                showsBorder: true,
            )
        } else if let image = providerLogoImage(for: provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(provider.usesExpandedLogo ? 2 : 9)
        } else {
            Image(systemName: iconName(for: provider))
                .font(
                    .system(
                        size: StudioTheme.ControlSize.modelProviderBadgeSymbol, weight: .semibold,
                    ),
                )
                .foregroundStyle(isFocused ? StudioTheme.accent : StudioTheme.textSecondary)
        }
    }

    private func providerLogoImage(for provider: StudioModelProviderID) -> NSImage? {
        guard let resourceName = providerLogoResourceName(for: provider) else { return nil }

        let url =
            Bundle.module.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Resources/Providers",
            )
            ?? Bundle.module.url(
                forResource: resourceName, withExtension: "png", subdirectory: "Providers",
            )
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "svg")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func providerLogoResourceName(for provider: StudioModelProviderID) -> String? {
        switch provider {
        case .freeSTT:
            nil
        case .whisperAPI, .multimodalLLM:
            "openai"
        case .ollama:
            "ollama"
        case .freeModel:
            nil
        case .openRouter:
            "openrouter"
        case .openAI:
            "openai"
        case .anthropic:
            "claude-color"
        case .gemini:
            "gemini-color"
        case .deepSeek:
            "deepseek-color"
        case .kimi:
            "moonshot"
        case .qwen:
            "qwen-color"
        case .zhipu:
            "zhipu-color"
        case .minimax:
            "minimax-color"
        case .grok:
            "xai"
        case .groq:
            "groq"
        case .groqSTT:
            "groq"
        case .googleCloud:
            "google"
        case .xiaomi:
            "xiaomimimo"
        case .aliCloud:
            "bailian-color"
        case .doubaoRealtime:
            "doubao-color"
        default:
            nil
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
                        HStack(spacing: StudioTheme.Spacing.xSmall) {
                            Text(model.displayName)
                                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)

                            if let recommendationBadgeTitle = model.recommendationBadgeTitle {
                                localSTTRecommendationPill(recommendationBadgeTitle)
                            }
                        }

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
                            fill: StudioTheme.accentSoft,
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
                        isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted.opacity(0.45),
                    ),
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isSelected
                            ? StudioTheme.accent.opacity(0.65) : StudioTheme.border.opacity(0.75),
                        lineWidth: isSelected
                            ? StudioTheme.BorderWidth.emphasis : StudioTheme.BorderWidth.thin,
                    ),
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
                    .fill(StudioTheme.surface),
            )
    }

    private func localSTTRecommendationPill(_ text: String) -> some View {
        Text(text)
            .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
            .foregroundStyle(Color.green.opacity(0.95))
            .padding(.horizontal, StudioTheme.Insets.pillHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.green.opacity(0.16)),
            )
    }

    private func providerIsConfigured(_ provider: StudioModelProviderID) -> Bool {
        switch provider {
        case .appleSpeech:
            true
        case .localSTT:
            true
        case .freeSTT:
            !viewModel.freeSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && FreeSTTModelRegistry.resolve(modelName: viewModel.freeSTTModel) != nil
        case .whisperAPI:
            !viewModel.whisperAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ollama:
            !viewModel.ollamaModel.isEmpty
        case .freeModel:
            !viewModel.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && FreeLLMModelRegistry.resolve(modelName: viewModel.llmModel) != nil
        case .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu,
             .minimax, .grok, .groq, .xiaomi:
            !viewModel.llmAPIKey.isEmpty && !viewModel.llmBaseURL.isEmpty
                && !viewModel.llmModel.isEmpty
        case .multimodalLLM:
            !viewModel.multimodalLLMBaseURL.isEmpty && !viewModel.multimodalLLMModel.isEmpty
        case .aliCloud:
            !viewModel.aliCloudAPIKey.isEmpty
        case .doubaoRealtime:
            !viewModel.doubaoAppID.isEmpty && !viewModel.doubaoAccessToken.isEmpty
        case .googleCloud:
            !viewModel.googleCloudProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !viewModel.googleCloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .groqSTT:
            !viewModel.groqSTTAPIKey.isEmpty
        case .typefluxOfficial:
            authState.isLoggedIn
        case .typefluxCloud:
            authState.isLoggedIn
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
                    ? OpenAIAudioModelCatalog.defaultWhisperModel(
                        forEndpoint: viewModel.whisperBaseURL,
                    ) : viewModel.whisperModel,
            )
        case .ollama:
            viewModel.applyModelConfiguration(shouldShowToast: false)
            viewModel.setLLMModelSelection(
                .ollama,
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel,
            )
            viewModel.prepareOllamaModel()
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
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
                    ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel,
            )
        case .aliCloud:
            viewModel.setSTTProvider(.aliCloud)
        case .doubaoRealtime:
            viewModel.setSTTProvider(.doubaoRealtime)
        case .googleCloud:
            viewModel.setSTTProvider(.googleCloud)
        case .groqSTT:
            viewModel.setSTTProvider(.groq)
        case .typefluxOfficial:
            viewModel.setSTTProvider(.typefluxOfficial)
        case .typefluxCloud:
            viewModel.setLLMRemoteProvider(.typefluxCloud)
        }
    }

    private func iconName(for provider: StudioModelProviderID) -> String {
        switch provider {
        case .appleSpeech:
            "waveform"
        case .localSTT:
            "laptopcomputer.and.arrow.down"
        case .freeSTT:
            "giftcard"
        case .whisperAPI:
            "dot.radiowaves.left.and.right"
        case .ollama:
            "cpu"
        case .freeModel:
            "giftcard"
        case .customLLM:
            "xmark.triangle.circle.square.fill"
        case .openRouter:
            "arrow.triangle.branch"
        case .openAI:
            "circle.hexagongrid"
        case .anthropic:
            "sun.max"
        case .gemini:
            "diamond"
        case .deepSeek:
            "bird"
        case .kimi:
            "moon.stars"
        case .qwen:
            "cloud"
        case .zhipu:
            "dot.scope"
        case .minimax:
            "sparkles"
        case .grok:
            "x.circle"
        case .groq:
            "bolt.fill"
        case .groqSTT:
            "bolt.fill"
        case .xiaomi:
            "circle.grid.cross"
        case .multimodalLLM:
            "brain.filled.head.profile"
        case .aliCloud:
            "antenna.radiowaves.left.and.right"
        case .doubaoRealtime:
            "bolt.horizontal.circle"
        case .googleCloud:
            "cloud"
        case .typefluxOfficial:
            "infinity"
        case .typefluxCloud:
            "infinity"
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
            L("settings.models.overview.appleSpeech")
        case .localSTT:
            L("settings.models.overview.localSTT")
        case .freeSTT:
            L("settings.models.overview.freeSTT")
        case .whisperAPI:
            L("settings.models.overview.whisper")
        case .ollama:
            L("settings.models.overview.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            L("settings.models.overview.remoteProvider", activeLLMRemoteProvider.displayName)
        case .typefluxCloud:
            L("settings.models.overview.typefluxCloud")
        case .multimodalLLM:
            L("settings.models.overview.multimodal")
        case .aliCloud:
            L("settings.models.overview.aliCloud")
        case .doubaoRealtime:
            L("settings.models.overview.doubao")
        case .googleCloud:
            L("settings.models.overview.googleCloud")
        case .groqSTT:
            L("settings.models.overview.groq")
        case .typefluxOfficial:
            L("settings.models.overview.typefluxOfficial")
        }
    }

    private var modelOverviewProviderPill: String {
        switch activeModelProviderID {
        case .appleSpeech:
            STTProvider.appleSpeech.displayName
        case .localSTT:
            STTProvider.localModel.displayName
        case .freeSTT:
            STTProvider.freeModel.displayName
        case .whisperAPI:
            STTProvider.whisperAPI.displayName
        case .ollama:
            LLMProvider.ollama.displayName
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            activeLLMRemoteProvider.displayName
        case .typefluxCloud:
            LLMRemoteProvider.typefluxCloud.displayName
        case .multimodalLLM:
            STTProvider.multimodalLLM.displayName
        case .aliCloud:
            STTProvider.aliCloud.displayName
        case .doubaoRealtime:
            STTProvider.doubaoRealtime.displayName
        case .googleCloud:
            STTProvider.googleCloud.displayName
        case .groqSTT:
            STTProvider.groq.displayName
        case .typefluxOfficial:
            STTProvider.typefluxOfficial.displayName
        }
    }

    private var modelOverviewModePill: String {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            L("settings.models.mode.local")
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial, .typefluxCloud:
            L("settings.models.mode.remote")
        }
    }

    private var modelOverviewModeTone: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            StudioTheme.success
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial, .typefluxCloud:
            StudioTheme.accent
        }
    }

    private var modelOverviewModeFill: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            StudioTheme.success.opacity(0.12)
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .typefluxOfficial, .typefluxCloud:
            StudioTheme.accentSoft
        }
    }

    @ViewBuilder
    private func apiKeyHelpButton(url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "key")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("onboarding.models.getAPIKey"))
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(StudioTheme.accent)
        }
        .buttonStyle(.plain)
    }

    private func sttProviderAPIKeyURL(_ provider: STTProvider) -> URL? {
        switch provider {
        case .whisperAPI:
            URL(string: "https://platform.openai.com/api-keys")
        case .groq:
            URL(string: "https://console.groq.com/keys")
        case .aliCloud:
            URL(string: "https://bailian.console.aliyun.com?tab=model#/api-key")
        case .multimodalLLM:
            URL(string: "https://platform.openai.com/api-keys")
        case .googleCloud:
            URL(string: "https://console.cloud.google.com/apis/credentials")
        case .doubaoRealtime, .freeModel, .localModel, .appleSpeech, .typefluxOfficial:
            nil
        }
    }

    private func llmProviderAPIKeyURL(_ provider: LLMRemoteProvider) -> URL? {
        switch provider {
        case .openAI:
            URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:
            URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:
            URL(string: "https://aistudio.google.com/apikey")
        case .deepSeek:
            URL(string: "https://platform.deepseek.com/api_keys")
        case .groq:
            URL(string: "https://console.groq.com/keys")
        case .openRouter:
            URL(string: "https://openrouter.ai/settings/keys")
        case .kimi:
            URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .qwen:
            URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .zhipu:
            URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikey")
        case .minimax:
            URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        case .grok:
            URL(string: "https://console.x.ai/")
        case .xiaomi:
            URL(string: "https://ai.xiaomi.com/")
        case .freeModel, .custom:
            nil
        case .typefluxCloud:
            nil
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
            STTProvider.appleSpeech.displayName
        case .localSTT:
            viewModel.localSTTModel.displayName
        case .freeSTT:
            viewModel.freeSTTModel.isEmpty
                ? L("settings.models.modelNotConfigured") : viewModel.freeSTTModel
        case .whisperAPI:
            viewModel.whisperModel.isEmpty
                ? OpenAIAudioModelCatalog.defaultWhisperModel(
                    forEndpoint: viewModel.whisperBaseURL,
                ) : viewModel.whisperModel
        case .ollama:
            viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            viewModel.llmModel.isEmpty
                ? activeLLMRemoteProvider.defaultModel : viewModel.llmModel
        case .multimodalLLM:
            viewModel.multimodalLLMModel.isEmpty
                ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel
        case .aliCloud:
            AliCloudASRDefaults.model
        case .doubaoRealtime:
            L("settings.models.doubao.productName")
        case .googleCloud:
            viewModel.googleCloudModel.isEmpty ? GoogleCloudSpeechDefaults.model : viewModel.googleCloudModel
        case .groqSTT:
            viewModel.groqSTTModel.isEmpty
                ? OpenAIAudioModelCatalog.groqWhisperModels[0] : viewModel.groqSTTModel
        case .typefluxOfficial:
            STTProvider.typefluxOfficial.displayName
        case .typefluxCloud:
            LLMRemoteProvider.typefluxCloud.displayName
        }
    }

    private var modelOverviewModelHint: String {
        providerIsConfigured(activeModelProviderID)
            ? L("settings.models.readyForUse") : L("settings.models.configurationNeeded")
    }

    private var focusedProviderTitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            STTProvider.appleSpeech.displayName
        case .localSTT:
            L("settings.models.localSpeechModels")
        case .freeSTT:
            STTProvider.freeModel.displayName
        case .whisperAPI:
            STTProvider.whisperAPI.displayName
        case .ollama:
            LLMProvider.ollama.displayName
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            focusedLLMRemoteProvider?.displayName ?? LLMProvider.openAICompatible.displayName
        case .multimodalLLM:
            STTProvider.multimodalLLM.displayName
        case .aliCloud:
            STTProvider.aliCloud.displayName
        case .doubaoRealtime:
            STTProvider.doubaoRealtime.displayName
        case .googleCloud:
            STTProvider.googleCloud.displayName
        case .groqSTT:
            STTProvider.groq.displayName
        case .typefluxOfficial:
            STTProvider.typefluxOfficial.displayName
        case .typefluxCloud:
            LLMRemoteProvider.typefluxCloud.displayName
        }
    }

    private var focusedProviderSubtitle: String {
        switch viewModel.focusedModelProvider {
        case .appleSpeech:
            L("settings.models.focused.appleSpeech")
        case .localSTT:
            L("settings.models.focused.localSTT")
        case .freeSTT:
            L("settings.models.focused.freeSTT")
        case .whisperAPI:
            L("settings.models.focused.whisper")
        case .ollama:
            L("settings.models.focused.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            L(
                "settings.models.focused.remoteProvider",
                focusedLLMRemoteProvider?.displayName ?? LLMProvider.openAICompatible.displayName,
            )
        case .multimodalLLM:
            L("settings.models.focused.multimodal")
        case .aliCloud:
            L("settings.models.focused.aliCloud")
        case .doubaoRealtime:
            L("settings.models.focused.doubao")
        case .googleCloud:
            L("settings.models.focused.googleCloud")
        case .groqSTT:
            L("settings.models.focused.groq")
        case .typefluxOfficial:
            L("settings.models.focused.typefluxOfficial")
        case .typefluxCloud:
            L("settings.models.focused.typefluxCloud")
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
            L("settings.models.routing.appleSpeech")
        case .localSTT:
            L("settings.models.routing.localSTT")
        case .freeSTT:
            L("settings.models.routing.freeSTT")
        case .whisperAPI:
            L("settings.models.routing.whisper")
        case .ollama:
            L("settings.models.routing.ollama")
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi:
            L("settings.models.routing.remoteProvider", activeLLMRemoteProvider.displayName)
        case .multimodalLLM:
            L("settings.models.routing.multimodal")
        case .aliCloud:
            L("settings.models.routing.aliCloud")
        case .doubaoRealtime:
            L("settings.models.routing.doubao")
        case .googleCloud:
            L("settings.models.routing.googleCloud")
        case .groqSTT:
            L("settings.models.routing.groq")
        case .typefluxOfficial:
            L("settings.models.routing.typefluxOfficial")
        case .typefluxCloud:
            L("settings.models.routing.typefluxCloud")
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

    // MARK: - Agent Jobs Sheet

    private var agentJobsSheet: some View {
        VStack(spacing: 0) {
            if let job = viewModel.selectedJobDetail {
                agentJobDetailView(job: job)
            } else {
                agentJobsListView
            }
        }
        .frame(width: 820, height: 680)
        .background(StudioTheme.background)
        .confirmationDialog(
            L("agent.jobs.clearAllDialog.title"),
            isPresented: $showingClearAllJobsConfirmation,
            titleVisibility: .visible,
        ) {
            Button(L("common.delete"), role: .destructive) {
                viewModel.clearAllAgentJobs()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("agent.jobs.clearAllDialog.message"))
        }
        .confirmationDialog(
            L("agent.jobs.deleteDialog.title"),
            isPresented: Binding(
                get: { agentJobPendingDeletion != nil },
                set: { if !$0 { agentJobPendingDeletion = nil } },
            ),
            titleVisibility: .visible,
        ) {
            Button(L("common.delete"), role: .destructive) {
                guard let job = agentJobPendingDeletion else { return }
                viewModel.deleteAgentJob(id: job.id)
                agentJobPendingDeletion = nil
            }
            Button(L("common.cancel"), role: .cancel) {
                agentJobPendingDeletion = nil
            }
        } message: {
            if let job = agentJobPendingDeletion {
                Text(L("agent.jobs.deleteDialog.message", job.displayTitle))
            }
        }
    }

    private var agentJobsListView: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
            // Header
            HStack(alignment: .center) {
                Text(L("agent.jobs.title"))
                    .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                if !viewModel.agentJobs.isEmpty {
                    StudioButton(
                        title: L("agent.jobs.clearAll"),
                        systemImage: "trash",
                        variant: .secondary,
                    ) {
                        showingClearAllJobsConfirmation = true
                    }
                }

                jobsCloseButton(action: viewModel.closeJobsPage)
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.top, StudioTheme.Spacing.large)

            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

            // Jobs list
            if viewModel.isLoadingJobs, viewModel.agentJobs.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                Spacer()
            } else if viewModel.agentJobs.isEmpty {
                Spacer()
                VStack(spacing: StudioTheme.Spacing.medium) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Text(L("agent.jobs.empty"))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .regular))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.agentJobs) { job in
                            agentJobRow(job)
                            if job.id != viewModel.agentJobs.last?.id {
                                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentJobRow(_ job: AgentJob) -> some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
            Circle()
                .fill(jobStatusColor(job.status))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(job.displayTitle)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: StudioTheme.Spacing.small) {
                    Text(jobTimeText(job.createdAt))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textTertiary)

                    if let duration = job.formattedDuration {
                        Text("·")
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text(duration)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }

                    if job.totalToolCalls > 0 {
                        Text("·")
                            .foregroundStyle(StudioTheme.textTertiary)
                        Label(
                            L("agent.jobs.toolCalls", job.totalToolCalls),
                            systemImage: "wrench",
                        )
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textTertiary)
                    }

                    if let tokens = job.formattedTotalTokens {
                        Text("·")
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text(tokens)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
        }
        .padding(.horizontal, StudioTheme.Spacing.large)
        .padding(.vertical, StudioTheme.Spacing.medium)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectJob(job)
        }
        .contextMenu {
            Button(L("common.delete"), role: .destructive) {
                agentJobPendingDeletion = job
            }
        }
    }

    // MARK: - Agent Job Detail

    // swiftlint:disable:next function_body_length
    private func agentJobDetailView(job: AgentJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with centered title, back on the left, close on the right.
            ZStack {
                HStack {
                    Button(action: viewModel.closeJobDetail) {
                        HStack(spacing: StudioTheme.Spacing.xSmall) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                            Text(L("agent.jobs.title"))
                                .font(.studioBody(StudioTheme.Typography.body))
                        }
                        .foregroundStyle(StudioTheme.accent)
                        .frame(minWidth: 120, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    jobsCloseButton(action: viewModel.closeJobsPage)
                        .frame(minWidth: 120, alignment: .trailing)
                }

                Text(job.displayTitle)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 140)
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.top, StudioTheme.Spacing.large)
            .padding(.bottom, StudioTheme.Spacing.medium)

            // Job metadata
            HStack(spacing: StudioTheme.Spacing.small) {
                Circle()
                    .fill(jobStatusColor(job.status))
                    .frame(width: 10, height: 10)

                Text(jobDetailTimeText(job.createdAt))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)

                if let duration = job.formattedDuration {
                    StudioPill(title: duration)
                }

                StudioPill(title: L("agent.jobs.steps", job.steps.count))

                if job.totalToolCalls > 0 {
                    StudioPill(title: L("agent.jobs.toolCalls", job.totalToolCalls))
                }

                if let tokens = job.formattedTotalTokens {
                    StudioPill(title: tokens)
                }
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.bottom, StudioTheme.Spacing.medium)

            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
                    jobSection(title: L("agent.jobs.detail.prompt"), icon: "person.fill", cardPadding: 12) {
                        Text(job.userPrompt)
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .textSelection(.enabled)
                    }

                    if let selectedText = job.selectedText, !selectedText.isEmpty {
                        jobSection(title: L("agent.jobs.detail.context"), icon: "text.quote", cardPadding: 12) {
                            ExpandableContextView(text: selectedText)
                        }
                    }

                    if !job.steps.isEmpty {
                        jobSection(title: L("agent.jobs.detail.steps"), icon: "list.number") {
                            ForEach(job.steps) { step in
                                jobStepView(step, isLast: step.id == job.steps.last?.id)
                            }
                        }
                    }

                    if let result = job.resultText, !result.isEmpty {
                        jobSection(title: L("agent.jobs.detail.result"), icon: "sparkles", cardPadding: 12) {
                            Text(result)
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }

                    if let error = job.errorMessage, !error.isEmpty {
                        jobSection(title: L("agent.jobs.detail.error"), icon: "exclamationmark.triangle.fill", cardPadding: 12) {
                            Text(error)
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.danger)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(StudioTheme.Spacing.large)
            }
        }
    }

    private func jobSection(
        title: String,
        icon: String,
        cardPadding: CGFloat = StudioTheme.Insets.cardDefault,
        @ViewBuilder content: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.Typography.iconSmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            StudioCard(padding: cardPadding) {
                content()
            }
        }
    }

    private func jobStepView(_ step: AgentJobStep, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            // Step header: number, description, timing
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Text(L("agent.jobs.detail.stepNumber", step.stepIndex + 1))
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)

                Text("·")
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)

                Text(step.stepDescription)
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Token usage badge for this step
                if let usage = step.tokenUsage, usage.totalTokens > 0 {
                    Text(L("agent.jobs.detail.stepTokens", usage.totalTokens))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textTertiary)
                }

                Text(step.formattedDuration)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)
            }

            // Assistant reasoning/decision text
            if let text = step.assistantText, !text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: StudioTheme.Spacing.xSmall) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text(L("agent.jobs.detail.reasoning"))
                            .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                    Text(text)
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(StudioTheme.surface.opacity(0.5))
                .cornerRadius(6)
            }

            ForEach(step.toolCalls) { toolCall in
                JobToolCallRow(toolCall: toolCall)
            }

            if !isLast {
                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
            }
        }
    }

    // MARK: - Job Helpers

    private func jobsCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StudioTheme.surfaceMuted))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func jobStatusColor(_ status: AgentJobStatus) -> Color {
        switch status {
        case .running: StudioTheme.warning
        case .completed: StudioTheme.success
        case .failed: StudioTheme.danger
        }
    }

    private func jobTimeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func jobDetailTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct VocabularyTermCard: View {
    let entry: VocabularyEntry
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: entry.source == .automatic ? "sparkles" : "plus.circle.fill")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                .foregroundStyle(entry.source == .automatic ? StudioTheme.warning : StudioTheme.accent)

            Text(entry.term)
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: StudioTheme.Spacing.small)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .bold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(StudioTheme.surfaceMuted.opacity(0.8)),
                    )
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .padding(.horizontal, StudioTheme.Insets.cardCompact)
        .padding(.vertical, StudioTheme.Insets.buttonVertical)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(StudioTheme.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin,
                ),
        )
        .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L("common.copy"), systemImage: "doc.on.doc", action: onCopy)
            Button(L("common.edit"), systemImage: "pencil", action: onEdit)
            Button(L("common.delete"), systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// Context text that collapses to 5 lines by default with an expand/collapse toggle.
/// Only shows the toggle when the text actually exceeds the collapsed line limit.
private struct ExpandableContextView: View {
    let text: String

    private static let collapsedLineLimit = 5

    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    // Invisible full-text view used to detect truncation
                    GeometryReader { fullGeo in
                        Text(text)
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .lineLimit(Self.collapsedLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { truncGeo in
                                    Color.clear.onAppear {
                                        isTruncated = truncGeo.size.height < fullGeo.size.height
                                    }
                                },
                            )
                            .hidden()
                    },
                )

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded
                        ? L("agent.jobs.detail.context.showLess")
                        : L("agent.jobs.detail.context.showMore"))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(StudioTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single tool call row in the agent job step detail.
/// Clicking the function name toggles visibility of the function parameters (argumentsJSON).
private struct JobToolCallRow: View {
    let toolCall: AgentJobToolCall

    @State private var showParameters = false

    var body: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
            Image(systemName: toolCall.isError ? "xmark.circle.fill" : "wrench.fill")
                .font(.system(size: 10))
                .foregroundStyle(toolCall.isError ? StudioTheme.danger : StudioTheme.accent)
                .padding(.top, 3)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showParameters.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(toolCall.name)
                            .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Image(systemName: showParameters ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                .buttonStyle(.plain)

                if showParameters, !toolCall.argumentsJSON.isEmpty, toolCall.argumentsJSON != "{}" {
                    Text(toolCall.argumentsJSON)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(StudioTheme.surface.opacity(0.5))
                        .cornerRadius(4)
                }

                if !toolCall.resultContent.isEmpty {
                    Text(toolCall.resultContent)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
