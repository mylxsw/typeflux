import AppKit
import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable file_length
private enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all
    case automatic
    case manual
    case otherApps

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
        case .otherApps:
            L("vocabulary.filter.otherApps")
        }
    }

    func matches(_ source: VocabularySource) -> Bool {
        switch self {
        case .all:
            // The "All" filter intentionally includes every vocabulary source.
            true
        case .automatic:
            source == .automatic
        case .manual:
            source == .manual
        case .otherApps:
            source.isExternalAppSource
        }
    }

}

private func logoResourceName(for source: VocabularySource) -> String? {
    switch source {
    case .claude:
        "claude-color"
    case .codex:
        "openai"
    case .manual, .automatic:
        nil
    }
}

private func vocabularySourceLogoImage(for source: VocabularySource) -> NSImage? {
    guard let resourceName = logoResourceName(for: source) else { return nil }
    guard let url = vocabularySourceLogoURL(for: resourceName) else {
        ErrorLogStore.shared.log(
            "Missing vocabulary source logo resource for \(source.rawValue): \(resourceName)"
        )
        return nil
    }
    return NSImage(contentsOf: url)
}

private func vocabularySourceMenuIconImage(for source: VocabularySource) -> NSImage? {
    guard let image = vocabularySourceLogoImage(for: source) else { return nil }
    let iconSize = NSSize(width: 16, height: 16)
    return NSImage(size: iconSize, flipped: false) { destinationRect in
        image.draw(
            in: destinationRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        return true
    }
}

private func vocabularySourceLogoURL(for resourceName: String) -> URL? {
    let imageExtension = "png"
    let candidatePaths: [(String?, String)] = [
        ("Resources/Providers", imageExtension),
        ("Providers", imageExtension),
        (nil, imageExtension)
    ]

    for (subdirectory, pathExtension) in candidatePaths {
        if let url = Bundle.appResources.url(
            forResource: resourceName,
            withExtension: pathExtension,
            subdirectory: subdirectory
        ) {
            return url
        }
    }

    return nil
}

private struct StudioAutoHidingScrollIndicatorConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let scrollView = enclosingScrollView(from: nsView) else { return }
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
        }
    }

    private func enclosingScrollView(from view: NSView) -> NSScrollView? {
        var currentView: NSView? = view

        while let view = currentView {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            currentView = view.superview
        }

        return nil
    }
}

private extension View {
    func studioAutoHidingScrollIndicators() -> some View {
        background(
            StudioAutoHidingScrollIndicatorConfigurator()
                .frame(width: 0, height: 0)
        )
    }
}

private enum CloudServerStatusTone {
    case fast
    case average
    case slow
    case unavailable
    case untested

    var color: Color {
        switch self {
        case .fast:
            StudioTheme.success
        case .average:
            StudioTheme.warning
        case .slow, .unavailable:
            StudioTheme.danger
        case .untested:
            StudioTheme.textSecondary
        }
    }
}

private struct CloudServerPickerOption: Identifiable {
    let value: String
    let domain: String
    let tagText: String?
    let tone: CloudServerStatusTone

    var id: String {
        value
    }
}

// swiftlint:disable:next type_body_length
struct StudioView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var imageSettings: AskImageSettingsModel
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var isAddingVocabulary = false
    @State private var editingVocabularyEntry: VocabularyEntry?
    @State private var newVocabularyTerm = ""
    @State private var isRecentInputMemoryManagerPresented = false
    @State private var localSTTPendingDelete: LocalSTTModel?
    @State private var localSTTPendingDownload: LocalSTTModel?

    @State private var localSTTPendingRedownload: LocalSTTModel?
    @State private var llmActivationMissingAPIKeyProviderName: String?
    @State private var isMCPServerDialogPresented = false
    @State private var mcpServerPendingDeletion: MCPServerConfig?
    @State private var showingClearHistoryConfirmation = false
    @State private var agentPane: AgentSettingsPane
    @StateObject private var interfaceStyleObserver: InterfaceStyleObserver
    @State private var launcherPane: LauncherSettingsPane
    @State private var settingsPane: AppSettingsPane
    @StateObject private var moduleHealth: ModuleHealthSettingsModel

    /// `launcherPane` opens the Launcher page at one of its panes, e.g. the keyword list.
    init(viewModel: StudioViewModel, launcherPane: LauncherSettingsPane = .basics,
         settingsPane: AppSettingsPane = .general, agentPane: AgentSettingsPane = .overview,
         moduleHealth: ModuleHealthSettingsModel? = nil) {
        self.viewModel = viewModel
        _moduleHealth = StateObject(wrappedValue: moduleHealth ?? ModuleHealthSettingsModel(registry: nil))
        _interfaceStyleObserver = StateObject(wrappedValue: InterfaceStyleObserver(settings: viewModel.askToolSettings))
        _imageSettings = StateObject(wrappedValue: AskImageSettingsModel(
            store: AskImageSettings(defaults: viewModel.askToolSettings.defaults)
        ))
        _launcherPane = State(initialValue: launcherPane)
        _settingsPane = State(initialValue: settingsPane)
        _agentPane = State(initialValue: agentPane)
    }

    @State private var agentStatuses: [AgentCapabilityStatus] = []
    @State private var isMCPImportPresented = false
    @State private var mcpImportText = ""
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var authState = AuthState.shared

    var body: some View {
        StudioShell(
            currentSection: viewModel.currentSection,
            onSelect: viewModel.navigateFromSidebar,
            onAccountAction: handleAccountAction,
            searchText: $viewModel.searchQuery,
            searchPlaceholder: viewModel.currentSection.searchPlaceholder,
            accountDefaults: viewModel.askToolSettings.defaults
        ) { viewportSize in
            let viewportHeight = viewportContentHeight(from: viewportSize)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                if viewModel.currentSection.isVoiceInput || [.models, .settings].contains(viewModel.currentSection) {
                    StudioHeroHeader(
                        eyebrow: viewModel.currentSection.eyebrow,
                        title: viewModel.currentSection.sidebarSection.sidebarTitle
                    )
                    .accessibilityIdentifier("studio.page.title")
                }

                if viewModel.currentSection.isVoiceInput {
                    voiceInputHeader
                } else if viewModel.currentSection == .settings {
                    settingsHeader
                } else if viewModel.currentSection == .models {
                    modelsHeader
                } else {
                    pageHeader
                }

                if viewModel.currentSection == .models {
                    GeometryReader { proxy in
                        modelsPage(viewportHeight: proxy.size.height)
                    }
                } else if viewModel.currentSection == .personas {
                    personasPage
                        .frame(maxHeight: .infinity)
                } else {
                    currentPage(viewportWidth: viewportSize.width)
                }
            }
            .frame(
                height: [.models, .personas].contains(viewModel.currentSection) ? viewportHeight : nil,
                alignment: .top
            )
            .frame(
                minHeight: viewModel.currentSection == .vocabulary ? viewportHeight : nil,
                alignment: .topLeading
            )
            .id(viewModel.currentSection)
        }
        .interfaceStyle(following: interfaceStyleObserver)
        .onChange(of: interfaceStyleObserver.style) { viewModel.interfaceStyle = $0 }
        .onChange(of: interfaceStyleObserver.glassIntensity) { viewModel.liquidGlassIntensity = $0.value }
        .onAppear {
            AppLocalization.shared.setLanguage(viewModel.appLanguage)
            viewModel.schedulePermissionRefresh()
        }
        .task(id: authState.isLoggedIn) {
            guard authState.isLoggedIn else { return }
            await refreshSidebarAccountStatus()

            while !Task.isCancelled, authState.isLoggedIn {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await refreshSidebarAccountStatus()
            }
        }
        .preferredColorScheme(viewModel.preferredColorScheme)
        .environment(\.locale, viewModel.locale)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            viewModel.schedulePermissionRefresh()
            Task { await refreshSidebarAccountStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDidLogin)) { _ in
            Task { await refreshSidebarAccountStatus() }
        }
        .onReceive(viewModel.$settingsPaneRequest.compactMap { $0 }) { pane in
            settingsPane = pane
        }
        .onReceive(viewModel.$launcherPaneRequest.compactMap { $0 }) { pane in
            launcherPane = pane
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
                            StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin
                        )
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
                }
            )
        ) {
            vocabularyAddSheet
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
        .sheet(isPresented: $viewModel.isInstantVoiceInputSuggestionPresented) {
            InstantVoiceInputSuggestionView(
                onEnable: {
                    viewModel.setInstantVoiceInputEnabled(true)
                    viewModel.isInstantVoiceInputSuggestionPresented = false
                },
                onCancel: { viewModel.isInstantVoiceInputSuggestionPresented = false }
            )
        }
        .sheet(isPresented: $isMCPServerDialogPresented) {
            mcpServerDialog
        }
        .sheet(isPresented: $isRecentInputMemoryManagerPresented) {
            RecentInputMemoryManagementView(viewModel: viewModel)
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
        .confirmationDialog(
            L("history.clearDialog.title"),
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("common.clear"), role: .destructive) {
                viewModel.clearHistory()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("history.clearDialog.message"))
        }
    }

    private func handleAccountAction() {
        guard authState.isLoggedIn else {
            LoginWindowController.shared.show()
            return
        }

        viewModel.navigate(to: .account)
        Task { @MainActor in
            switch await authState.refreshProfile() {
            case .authenticated, .failed:
                break
            case .unauthenticated:
                LoginWindowController.shared.show()
            }
        }
    }

    private func refreshSidebarAccountStatus() async {
        guard authState.isLoggedIn else { return }

        await authState.refreshTokenIfNeeded()
        guard authState.isLoggedIn else { return }

        if !authState.isLoadingSubscription {
            await authState.refreshSubscription()
        }
        if !authState.isLoadingUsage {
            await authState.refreshUsage()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
            StudioHeroHeader(
                eyebrow: viewModel.currentSection.eyebrow,
                title: viewModel.currentSection.heading,
                subtitle: viewModel.currentSection == .agent ? nil : viewModel.currentSection.subheading
            )

            pageHeaderActions
        }
    }

    /// Voice Input pages share one header: their tabs, with the shown page's actions on the right.
    private var voiceInputHeader: some View {
        VoiceInputTabBar(
            selection: viewModel.currentSection,
            count: viewModel.voiceInputTabCount,
            onSelect: viewModel.navigate
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keep a clear gap below actions without moving the tab underline off the divider.
        .overlay(alignment: .bottom) {
            HStack(spacing: TFMetrics.toolbarSpacing) { pageHeaderActions }
                .padding(.bottom, 6)
        }
    }

    /// The Models page header shares its tabs and action alignment with Voice Input.
    private var modelsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: TFMetrics.toolbarSpacing) {
                modelTabs.fixedSize(horizontal: true, vertical: false)
                HStack(spacing: TFMetrics.toolbarSpacing) { pageHeaderActions }
                    .padding(.bottom, 6)
                    .frame(height: 0, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth)
            }
            VStack(alignment: .leading, spacing: 10) {
                modelTabs.frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.modelPageTab.domain != nil, !viewModel.isShowingModelProviderDetail {
                    HStack(spacing: TFMetrics.toolbarSpacing) { pageHeaderActions }
                }
            }
        }
    }

    private var modelTabs: some View {
        ModelPageTabBar(selection: viewModel.modelPageTab, onSelect: viewModel.selectModelPageTab)
    }

    /// Actions on the right of the page header, including the spacer that pushes them there.
    private var pageHeaderActions: some View {
        Group {
            if viewModel.currentSection == .vocabulary {
                Spacer()
                TFButton(title: L("vocabulary.action.newWord"), systemImage: "plus") {
                    editingVocabularyEntry = nil
                    newVocabularyTerm = ""
                    isAddingVocabulary = true
                }
                TFMenuButton(title: L("vocabulary.action.more"), actions: [
                    .action(L("vocabulary.action.importFile"), systemImage: "arrow.down.doc") {
                        viewModel.importVocabulary()
                    },
                    .action(L("vocabulary.action.export"), systemImage: "arrow.up.doc") {
                        viewModel.exportVocabulary()
                    },
                    .separator,
                    .imageAction(L("vocabulary.action.importClaude"),
                                 image: vocabularySourceMenuIconImage(for: .claude)) {
                        viewModel.importClaudeVocabulary()
                    },
                    .imageAction(L("vocabulary.action.importCodex"),
                                 image: vocabularySourceMenuIconImage(for: .codex)) {
                        viewModel.importCodexVocabulary()
                    }
                ])
                .disabled(viewModel.isSynchronizingVocabulary)
            } else if viewModel.currentSection == .models {
                Spacer()

                // Provider lists can be searched; a provider's own settings have nothing to search.
                if let domain = viewModel.modelPageTab.domain, !viewModel.isShowingModelProviderDetail {
                    TFSearchField(placeholder: L("models.search"), text: $viewModel.modelSearchQuery,
                                  identifier: "models.search")
                        .frame(width: 220)
                    if domain == .llm {
                        TFButton(title: L("models.addEndpoint"), systemImage: "plus") {
                            viewModel.isAddingModelEndpoint = true
                        }
                        .accessibilityIdentifier("models.addProvider")
                    }
                }
            } else if viewModel.currentSection == .account {
                Spacer()
            } else if viewModel.currentSection.isVoiceInput {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func currentPage(viewportWidth: CGFloat) -> some View {
        switch viewModel.currentSection {
        case .home:
            homePage(viewportWidth: viewportWidth)
        case .models:
            EmptyView()
        case .personas:
            personasPage
        case .vocabulary:
            vocabularyPage
        case .history:
            homePage(viewportWidth: viewportWidth)
        case .settings:
            settingsPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .agent:
            agentPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .launcher:
            launcherPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .ring:
            RingSettingsView(settingsStore: viewModel.askToolSettings)
        case .account:
            AccountView(authState: AuthState.shared) {
                viewModel.navigate(to: .home)
            }
        }
    }

    private func homePage(viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            StudioOverviewPanel(
                width: viewportWidth,
                transcriptionMinutesText: viewModel.transcriptionMinutesText,
                totalCharacters: viewModel.statsTotalCharacters,
                savedMinutes: viewModel.statsSavedMinutes,
                averagePaceWPM: viewModel.statsAveragePaceWPM
            )

            VStack(alignment: .leading, spacing: 6) {
                TFSectionHeader(title: L("home.transcriptionHistory")) {
                    HStack(spacing: TFMetrics.toolbarSpacing) {
                        TFButton(title: L("history.action.exportMarkdown"), systemImage: "square.and.arrow.up",
                                 kind: .plain, iconOnly: true) {
                            viewModel.exportHistory()
                        }
                        TFButton(title: L("common.clear"), systemImage: "trash", kind: .plain, iconOnly: true) {
                            showingClearHistoryConfirmation = true
                        }
                    }
                }
                historyContent
            }
        }
    }

    private func modelsPage(viewportHeight: CGFloat) -> some View {
        ModelSettingsPage(viewModel: viewModel, library: viewModel.modelLibrary) {
            focusedProviderConfigurationPanel
        }
        .frame(height: viewportHeight, alignment: .top)
    }

    /// The onboarding sheet uses the production editors without the settings sidebar.
    var onboardingModelEditor: some View {
        VStack(spacing: 12) {
            HStack(spacing: TFMetrics.toolbarSpacing) { pageHeaderActions }
            ModelSettingsPage(viewModel: viewModel, library: viewModel.modelLibrary) {
                focusedProviderConfigurationPanel
            }
        }
        .interfaceStyle(following: interfaceStyleObserver)
        .environment(\.locale, viewModel.locale)
    }

    private func viewportContentHeight(from viewportSize: CGSize) -> CGFloat {
        max(
            viewportSize.height - StudioTheme.Layout.shellContentTopInset
                - (viewModel.currentSection == .models ? 0 : StudioTheme.Layout.shellContentBottomInset),
            0
        )
    }

    private var personasPage: some View {
        StudioPersonaLibraryView(viewModel: viewModel) { persona in
            viewModel.personaPendingDeletion = persona
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection {
                TFFormRow(title: L("history.keep.title"), detail: L("history.keep.subtitle"), icon: "clock") {
                    TFPopUpButton(title: L("history.keep.title"),
                                  options: HistoryRetentionPolicy.allCases.map { TFOption($0, $0.title) },
                                  selection: Binding(get: { viewModel.historyRetentionPolicy },
                                                     set: viewModel.setHistoryRetentionPolicy),
                                  width: 160)
                }
            }
            groupedSessionStream(sections: viewModel.groupedHistory)
        }
    }

    private func groupedSessionStream(sections: [HistorySection]) -> some View {
        LazyVStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            if sections.isEmpty {
                TFCard { TFCardNote(text: L("history.empty")) }
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        TFSectionHeader(title: section.id)
                        historyCard(section.records)
                    }
                }
            }

            if viewModel.isLoadingMoreHistory {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    TFSpinner()
                    TFFootnote(text: L("history.loadingMore"))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if viewModel.canLoadMoreHistory {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        viewModel.loadMoreHistoryIfNeeded()
                    }
            }
        }
    }

    /// History records in one card, separated by hairlines.
    private func historyCard(_ records: [HistoryPresentationRecord]) -> some View {
        TFCard {
            ForEach(records) { record in
                if record.id != records.first?.id { TFDivider.form }
                StudioHistoryRow(
                    record: record,
                    onCopyResult: { viewModel.copyHistoryResult(id: record.id) },
                    onCopyTranscript: { viewModel.copyTranscript(id: record.id) },
                    onDownloadAudio: { viewModel.downloadAudio(id: record.id) },
                    onPlayAudio: { viewModel.playAudio(id: record.id) },
                    isAudioPlaying: viewModel.playingAudioRecordID == record.id,
                    onDelete: { viewModel.deleteHistoryRecord(id: record.id) },
                    onRetry: { viewModel.retryHistoryRecord(id: record.id) }
                )
            }
        }
    }

    private var vocabularyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFSearchField(placeholder: L("vocabulary.search.placeholder"), text: $viewModel.searchQuery,
                              resultCount: filteredVocabularyEntries.count, identifier: "vocabulary.search")
                TFFilterControl(title: L("vocabulary.filter.all"),
                                options: VocabularyFilter.allCases.map {
                                    TFOption($0, $0.title, count: vocabularyCount(for: $0))
                                },
                                selection: $vocabularyFilter, defaultValue: .all)
                Spacer(minLength: 0)
            }
            if filteredVocabularyEntries.isEmpty {
                TFCard {
                    TFEmptyState(systemImage: "character.book.closed", title: L("vocabulary.empty.title"),
                                 message: L("vocabulary.empty.subtitle")) { vocabularyEmptyActions }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading,
                          spacing: 10) {
                    ForEach(filteredVocabularyEntries) { entry in
                        vocabularyTermCard(entry)
                    }
                }
            }
        }
    }

    private var settingsHeader: some View {
        TFTabBar(options: AppSettingsPane.allCases.map { TFOption($0, $0.title) }, selection: $settingsPane,
                 identifier: { "studio.settings.tab.\($0.rawValue)" })
    }

    @ViewBuilder
    private func settingsPage(compact: Bool) -> some View {
        switch settingsPane {
        case .general:
            generalSettingsPage
        case .hotkeys:
            HotkeySettingsView(viewModel: viewModel, settingsStore: viewModel.askToolSettings, compact: compact)
        case .appearance:
            AppearanceSettingsView(viewModel: viewModel)
        case .permissions:
            PermissionsSettingsView()
        case .advanced:
            advancedSettingsPage
        }
    }

    /// General settings, grouped by app startup, voice input, text output, memory,
    /// screenshots, and updates and data.
    private var generalSettingsPage: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection(title: L("settings.general.app.title")) {
                settingSwitch(L("settings.launchAtLogin.title"), detail: L("settings.launchAtLogin.subtitle"),
                              isOn: Binding(get: { viewModel.launchAtLogin }, set: viewModel.setLaunchAtLogin))
            }

            TFFormSection(title: L("settings.general.voiceInput.title")) {
                settingSwitch(L("settings.instantVoiceInput.title"), detail: L("settings.instantVoiceInput.subtitle"),
                              badge: "Beta",
                              isOn: Binding(get: { viewModel.instantVoiceInputEnabled },
                                            set: viewModel.setInstantVoiceInputEnabled))
                TFDivider.form
                TFFormRow(title: L("settings.microphone.title"), detail: L("settings.microphone.subtitle")) {
                    TFPopUpButton(
                        title: L("settings.microphone.title"),
                        options: [TFOption(AudioDeviceManager.automaticDeviceID, L("settings.microphone.automatic"))]
                            + viewModel.availableMicrophones.map { TFOption($0.id, $0.name) },
                        selection: Binding(get: { viewModel.preferredMicrophoneID },
                                           set: viewModel.setPreferredMicrophoneID),
                        width: TFMetrics.formControlWidth
                    )
                    TFButton(title: L("common.refresh"), systemImage: "arrow.clockwise", iconOnly: true) {
                        viewModel.refreshAvailableMicrophones()
                    }
                }
                TFDivider.form
                settingSwitch(L("settings.mute.title"), detail: L("settings.mute.subtitle"),
                              isOn: Binding(get: { viewModel.muteSystemOutputDuringRecording },
                                            set: viewModel.setMuteSystemOutputDuringRecording))
                /*
                  Sound effects are temporarily disabled until there is time to optimize them.
                  Keep this setting UI for a future reintroduction.
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
                 */
            }

            if viewModel.isTextTransformationAvailable {
                TFFormSection(title: L("settings.output.title")) {
                    settingSwitch(L("settings.output.opencc.title"), detail: L("settings.output.opencc.subtitle"),
                                  isOn: Binding(get: { viewModel.textTransformationEnabled },
                                                set: { viewModel.setTextTransformationEnabled($0) }))
                    if viewModel.textTransformationEnabled {
                        TFDivider.form
                        TFFormRow(title: L("settings.output.opencc.config.title")) {
                            TFPopUpButton(
                                title: L("settings.output.opencc.config.title"),
                                options: ["s2twp", "s2tw", "s2hk", "t2s"].map {
                                    TFOption($0, L("settings.output.opencc.config.\($0)"))
                                },
                                selection: Binding(get: { viewModel.textTransformationRule },
                                                   set: { viewModel.setTextTransformationRule($0) }),
                                width: TFMetrics.formControlWidth
                            )
                        }
                    }
                }
            }

            TFFormSection(title: L("settings.general.memory.title")) {
                settingSwitch(L("settings.advanced.autoVocabulary.title"),
                              detail: L("settings.advanced.autoVocabulary.subtitle"),
                              isOn: Binding(get: { viewModel.automaticVocabularyCollectionEnabled },
                                            set: viewModel.setAutomaticVocabularyCollectionEnabled))
                TFDivider.form
                TFFormRow(title: L("settings.advanced.recentInputMemory.title"),
                          detail: L("settings.advanced.recentInputMemory.subtitle")) {
                    TFButton(title: L("settings.advanced.recentInputMemory.manage"), kind: .link) {
                        isRecentInputMemoryManagerPresented = true
                    }
                    TFSwitch(title: L("settings.advanced.recentInputMemory.title"),
                             isOn: Binding(get: { viewModel.recentInputMemoryEnabled },
                                           set: viewModel.setRecentInputMemoryEnabled))
                }
                .onAppear { viewModel.refreshRecentInputMemoryApplications() }
                TFDivider.form
                settingSwitch(L("settings.advanced.globalSoul.title"), detail: L("settings.advanced.globalSoul.subtitle"),
                              isOn: Binding(get: { viewModel.globalSoulMemoryEnabled },
                                            set: viewModel.setGlobalSoulMemoryEnabled))
            }

            TFFormSection(title: L("settings.general.screenshot.title")) {
                screenshotSaveLocationSetting
            }

            TFFormSection(title: L("settings.general.updatesAndData.title")) {
                settingSwitch(L("settings.advanced.autoUpdate.title"), detail: L("settings.advanced.autoUpdate.subtitle"),
                              isOn: Binding(get: { viewModel.autoUpdateEnabled }, set: viewModel.setAutoUpdateEnabled))
                TFDivider.form
                settingSwitch(L("settings.analyticsSharing.title"), detail: L("settings.analyticsSharing.subtitle"),
                              isOn: Binding(get: { viewModel.analyticsSharingEnabled },
                                            set: viewModel.setAnalyticsSharingEnabled))
            }
        }
        .onAppear { viewModel.suggestInstantVoiceInputForCurrentMicrophoneIfNeeded() }
    }

    /// A form row whose only control is a switch.
    private func settingSwitch(_ title: String, detail: String, badge: String? = nil,
                               isOn: Binding<Bool>) -> some View {
        TFFormRow(title: title, detail: detail, badge: badge) {
            TFSwitch(title: title, isOn: isOn)
        }
    }

    private var advancedSettingsPage: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            ModuleHealthSettingsView(model: moduleHealth)
            ShortcutLatencySettingsView()
            TFFormSection {
                /*
                  Local optimization is hidden because SenseVoice availability and the
                  cloud-local race are system-managed fallback policies, not user choices.
                  Keep this setting UI until the model lifecycle is fully unified.
                 StudioSettingRow(
                     title: L("settings.advanced.localOptimization.title"),
                     subtitle: L("settings.advanced.localOptimization.subtitle")
                 ) {
                     Toggle(
                         "",
                         isOn: Binding(
                             get: { viewModel.localOptimizationEnabled },
                             set: viewModel.setLocalOptimizationEnabled
                         )
                     )
                     .labelsHidden()
                     .toggleStyle(.switch)
                 }

                 Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                 */

                TFFormRow(title: L("settings.advanced.voiceProcessingTimeout.title"),
                          detail: L("settings.advanced.voiceProcessingTimeout.subtitle")) {
                    TFPopUpButton(
                        title: L("settings.advanced.voiceProcessingTimeout.title"),
                        options: VoiceProcessingTimeout.allCases.map { TFOption($0, $0.displayName) },
                        selection: Binding(get: { viewModel.voiceProcessingTimeout },
                                           set: viewModel.setVoiceProcessingTimeout),
                        width: TFMetrics.formControlWidth
                    )
                }

                /*
                  Memory optimization is temporarily hidden and forced off until it can be
                  improved.
                  Keep this setting UI for a future reintroduction.
                 StudioSettingRow(
                     title: L("settings.advanced.localSTTMemoryOptimization.title"),
                     subtitle: L("settings.advanced.localSTTMemoryOptimization.subtitle")
                 ) {
                     Toggle(
                         "",
                         isOn: Binding(
                             get: { viewModel.localSTTMemoryOptimizationEnabled },
                             set: viewModel.setLocalSTTMemoryOptimizationEnabled
                         )
                     )
                     .labelsHidden()
                     .toggleStyle(.switch)
                 }

                 Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                 */

                /*
                  Applying personas to selected text now remains enabled without a user setting.
                  Keep this beta setting UI in case configurability returns later.
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
                 */

                /*
                  Input-context optimization now remains enabled without a user setting.
                  Keep this beta setting UI in case configurability returns later.
                 StudioSettingRow(
                     title: L("settings.advanced.inputContextOptimization.title"),
                     subtitle: L("settings.advanced.inputContextOptimization.subtitle"),
                     badge: "Beta"
                 ) {
                     Toggle(
                         "",
                         isOn: Binding(
                             get: { viewModel.inputContextOptimizationEnabled },
                             set: viewModel.setInputContextOptimizationEnabled
                         )
                     )
                     .labelsHidden()
                     .toggleStyle(.switch)
                 }

                 Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                 */

                /*
                  Apple Speech fallback is intentionally hidden from settings and should no longer
                  be presented to users. Keep the entry code because the underlying fallback remains.
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
                 */
            }

            cloudServerSettingsSection
        }
    }

    private var cloudServerSettingsSection: some View {
        TFFormSection(title: L("settings.servers.title")) {
            TFFormRow(title: L("settings.servers.api.title"), detail: L("settings.servers.api.subtitle")) {
                cloudServerPicker(
                    title: L("settings.servers.api.title"),
                    options: cloudServerOptions(servers: viewModel.availableAPIServers,
                                                statuses: viewModel.apiServerStatuses),
                    selection: Binding(get: { viewModel.preferredAPIServer }, set: viewModel.setPreferredAPIServer)
                )
            }
            TFDivider.form
            TFFormRow(title: L("settings.servers.asr.title"), detail: L("settings.servers.asr.subtitle")) {
                cloudServerPicker(
                    title: L("settings.servers.asr.title"),
                    options: cloudServerOptions(servers: viewModel.availableASRServers,
                                                statuses: viewModel.asrServerStatuses),
                    selection: Binding(get: { viewModel.preferredASRServer }, set: viewModel.setPreferredASRServer)
                )
            }
            TFDivider.form
            TFFormRow(title: L("settings.servers.speedTest.title"),
                      detail: L("settings.servers.speedTest.subtitle"),
                      valueText: viewModel.cloudServerTestSummary) {
                TFButton(
                    title: viewModel.isTestingCloudServers
                        ? L("settings.servers.speedTest.testing")
                        : L("settings.servers.speedTest.action"),
                    systemImage: "gauge.with.dots.needle.67percent",
                    isLoading: viewModel.isTestingCloudServers
                ) {
                    viewModel.testCloudServerLatency()
                }
            }
        }
    }

    /// Server domains with their latency grade as a colored tag.
    private func cloudServerPicker(title: String, options: [CloudServerPickerOption],
                                   selection: Binding<String>) -> some View {
        TFRichPicker(
            title: title,
            sections: [TFRichSection(options: options.map {
                TFRichOption($0.value, $0.domain, trailing: $0.tagText, trailingTint: $0.tone.color)
            })],
            selection: selection,
            searchable: false
        )
    }

    private func cloudServerOptions(
        servers: [String],
        statuses: [CloudEndpointStatus]
    ) -> [CloudServerPickerOption] {
        [
            CloudServerPickerOption(
                value: CloudServerPreferences.automaticValue,
                domain: L("settings.servers.automatic"),
                tagText: nil,
                tone: .untested
            )
        ] + servers.map { server in
            cloudServerOption(server, statuses: statuses)
        }
    }

    private func cloudServerOption(
        _ server: String,
        statuses: [CloudEndpointStatus]
    ) -> CloudServerPickerOption {
        let domain = URL(string: server)?.host ?? server
        guard let status = statuses.first(where: { $0.baseURL.absoluteString == server }) else {
            return CloudServerPickerOption(
                value: server,
                domain: domain,
                tagText: L("settings.servers.tag.notTested"),
                tone: .untested
            )
        }
        if status.lastError != nil {
            return CloudServerPickerOption(
                value: server,
                domain: domain,
                tagText: L("settings.servers.tag.unavailable"),
                tone: .unavailable
            )
        }
        guard let latencyMs = status.latencyMs else {
            return CloudServerPickerOption(
                value: server,
                domain: domain,
                tagText: L("settings.servers.tag.notTested"),
                tone: .untested
            )
        }

        let roundedLatency = Int(latencyMs.rounded())
        if latencyMs < 150 {
            return CloudServerPickerOption(
                value: server,
                domain: domain,
                tagText: L("settings.servers.tag.fast", roundedLatency),
                tone: .fast
            )
        }
        if latencyMs < 350 {
            return CloudServerPickerOption(
                value: server,
                domain: domain,
                tagText: L("settings.servers.tag.average", roundedLatency),
                tone: .average
            )
        }
        return CloudServerPickerOption(
            value: server,
            domain: domain,
            tagText: L("settings.servers.tag.slow", roundedLatency),
            tone: .slow
        )
    }

    // MARK: - Agent Page

    private func agentPage(compact: Bool) -> some View {
        TFPaneLayout(sections: AgentSettingsPane.sections.map { section in
            TFPaneSection(section.title, items: section.panes.map { pane in
                let status = agentPaneStatus(pane)
                return TFPaneItem(pane, pane.title, systemImage: pane.symbol, status: status?.level.paneStatus,
                                  statusLabel: status?.label)
            })
        }, selection: $agentPane) {
            VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
                if agentPane == .mcpServers {
                    TFPaneHeader(systemImage: AgentCapability.mcpServers.symbol,
                                 title: AgentCapability.mcpServers.title) {
                        if !viewModel.mcpServers.isEmpty {
                            TFButton(title: L("agent.mcp.import.action"), systemImage: "square.and.arrow.down") {
                                beginMCPImport()
                            }
                            TFButton(title: L("agent.mcp.addServer"), systemImage: "plus", kind: .primary) {
                                viewModel.beginAddMCPServer()
                                isMCPServerDialogPresented = true
                            }
                        }
                    }
                    agentMCPServersTabContent
                } else {
                    AskToolsSettingsView(
                        settings: viewModel.askToolSettings,
                        imageSettingsModel: imageSettings,
                        pane: agentPane,
                        onNavigate: { agentPane = $0 },
                        onStatusesChange: { agentStatuses = $0 }
                    )
                    // Rebuild per pane so each pane reloads its values when shown.
                    .id(agentPane)
                }
            }
        }
        .tfCompactLayout(compact)
        .sheet(isPresented: $isMCPImportPresented) { mcpImportSheet }
    }

    /// The state shown beside a pane in the list. MCP servers are edited here rather than in
    /// `AskToolsSettingsView`, so their state comes from the live server list.
    private func agentPaneStatus(_ pane: AgentSettingsPane) -> AgentCapabilityStatus? {
        guard let capability = pane.capability else { return nil }
        if capability == .mcpServers {
            return AgentCapabilityStatus.mcpStatus(for: viewModel.mcpServers)
        }
        return agentStatuses.first { $0.capability == capability }
    }

    private func launcherPage(compact: Bool) -> some View {
        TFPaneLayout(sections: [TFPaneSection(items: LauncherSettingsPane.allCases.map {
            TFPaneItem($0, $0.title, systemImage: $0.symbol)
        })], selection: $launcherPane) {
            LauncherSettingsView(
                settings: viewModel.askToolSettings, pane: launcherPane,
                clipboardHistory: SettingsWindowController.shared.clipboardHistoryStore,
                onEditShortcut: {
                    settingsPane = .hotkeys
                    viewModel.navigate(to: .settings)
                }
            )
            .id(launcherPane)
        }
        .tfCompactLayout(compact)
    }

    @ViewBuilder private var agentMCPServersTabContent: some View {
        if viewModel.mcpServers.isEmpty {
            TFCard {
                TFEmptyState(systemImage: "server.rack", title: L("agent.mcp.emptyTitle")) {
                    TFButton(title: L("agent.mcp.addServer"), systemImage: "plus", kind: .primary) {
                        viewModel.beginAddMCPServer()
                        isMCPServerDialogPresented = true
                    }
                    TFButton(title: L("agent.mcp.import.action"), systemImage: "square.and.arrow.down") {
                        beginMCPImport()
                    }
                }
            }
        } else {
            TFFormSection(footnote: L("agent.mcp.listHint")) {
                ForEach(Array(viewModel.mcpServers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { TFDivider.formWithIcon }
                    mcpServerRow(server)
                }
            }
        }
    }

    private func mcpServerRow(_ server: MCPServerConfig) -> some View {
        let status = MCPServerStatusPresentation(enabled: server.enabled, result: viewModel.mcpServerTestResults[server.id])
        let result = viewModel.mcpServerTestResults[server.id]
        return VStack(alignment: .leading, spacing: 0) {
            TFFormRow(
                title: server.name.isEmpty ? L("agent.mcp.untitled") : server.name,
                valueText: mcpTransportDetail(for: server),
                icon: "server.rack",
                valueLineLimit: 1,
                badge: mcpTransportLabel(for: server)
            ) {
                if status.isTesting {
                    TFSpinner()
                }
                TFStatusLabel(text: status.label, level: status.level)
                TFSwitch(title: server.name, isOn: Binding(
                    get: { server.enabled },
                    set: { viewModel.updateMCPServerEnabled(id: server.id, enabled: $0) }
                ))
                TFMenuButton(title: L("agent.mcp.more"), systemImage: "ellipsis", kind: .plain, size: .small,
                             iconOnly: true, actions: mcpServerActions(server))
            }
            if case let .failure(message)? = result {
                TFFieldMessage(text: message)
                    .padding(.leading, TFListGroupInset.formWithIcon).padding(.trailing, 14).padding(.bottom, 12)
            } else if case let .success(tools)? = result, !tools.isEmpty {
                TFFieldMessage(text: L("agent.mcp.toolList", tools.map(\.name).joined(separator: ", ")), tone: .hint)
                    .lineLimit(2)
                    .padding(.leading, TFListGroupInset.formWithIcon).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.beginEditMCPServer(server)
            isMCPServerDialogPresented = true
        }
        .contextMenu { mcpServerMenuItems(server) }
    }

    private func mcpServerActions(_ server: MCPServerConfig) -> [TFMenuAction] {
        [
            .action(L("agent.mcp.testConnection"), isEnabled: !viewModel.isTestingMCPServer(server.id)) {
                viewModel.testMCPConnection(for: server)
            },
            .action(L("agent.mcp.edit")) {
                viewModel.beginEditMCPServer(server)
                isMCPServerDialogPresented = true
            },
            .action(L("agent.mcp.duplicate")) { viewModel.duplicateMCPServer(id: server.id) },
            .separator,
            .action(L("common.delete"), destructive: true) { mcpServerPendingDeletion = server }
        ]
    }

    @ViewBuilder
    private func mcpServerMenuItems(_ server: MCPServerConfig) -> some View {
        Button(L("agent.mcp.testConnection")) { viewModel.testMCPConnection(for: server) }
            .disabled(viewModel.isTestingMCPServer(server.id))
        Button(L("agent.mcp.edit")) {
            viewModel.beginEditMCPServer(server)
            isMCPServerDialogPresented = true
        }
        Button(L("agent.mcp.duplicate")) { viewModel.duplicateMCPServer(id: server.id) }
        Divider()
        Button(L("common.delete"), role: .destructive) {
            mcpServerPendingDeletion = server
        }
    }

    private func beginMCPImport() {
        mcpImportText = ""
        isMCPImportPresented = true
    }

    private var mcpImportSheet: some View {
        let parsed = Result(catching: { try MCPServerImport.parse(mcpImportText, existingNames: viewModel.mcpServers.map(\.name)) })
        let servers = (try? parsed.get())?.servers ?? []
        return VStack(alignment: .leading, spacing: 14) {
            Text(L("agent.mcp.import.title"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("agent.mcp.import.hint")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $mcpImportText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 180)
                .background(ModelVisualStyle.control,
                            in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                    .strokeBorder(ModelVisualStyle.border))
                .accessibilityLabel(L("agent.mcp.import.title"))
            if !mcpImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch parsed {
                case let .success(result):
                    VStack(alignment: .leading, spacing: 4) {
                        if !result.servers.isEmpty {
                            Text(L("agent.mcp.import.preview", result.servers.count,
                                   result.servers.map(\.name).joined(separator: L("agent.listSeparator"))))
                        }
                        if !result.skipped.isEmpty {
                            Text(L("agent.mcp.import.skipped", result.skipped.joined(separator: L("agent.listSeparator"))))
                                .foregroundStyle(StudioTheme.warning)
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                case let .failure(error):
                    Text(error.localizedDescription).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                }
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { isMCPImportPresented = false }.buttonStyle(ModelActionStyle())
                Button(L("agent.mcp.import.confirm")) {
                    viewModel.importMCPServers(servers)
                    isMCPImportPresented = false
                }
                .buttonStyle(ModelActionStyle(primary: true))
                .disabled(servers.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(AskWindowBackdrop())
    }

    private var mcpServerDialog: some View {
        MCPServerEditorView(viewModel: viewModel) { isMCPServerDialogPresented = false }
    }

    private func mcpTransportLabel(for server: MCPServerConfig) -> String {
        switch server.transport {
        case .stdio: L("agent.mcp.transport.stdio")
        case .http: "HTTP"
        }
    }

    private func mcpTransportDetail(for server: MCPServerConfig) -> String {
        switch server.transport {
        case let .stdio(config): ([config.command] + config.args).joined(separator: " ")
        case let .http(config): config.url
        }
    }

    /// The folder ⌘S saves screenshots into.
    private var screenshotSaveLocationSetting: some View {
        TFFormRow(title: L("settings.shortcuts.screenshot.saveLocation.title"),
                  valueText: viewModel.screenshotSaveDirectory.path) {
            if viewModel.screenshotSaveDirectory.standardizedFileURL
                != SettingsStore.defaultScreenshotSaveDirectory.standardizedFileURL {
                TFButton(title: L("settings.shortcuts.screenshot.saveLocation.reset"), kind: .link) {
                    viewModel.resetScreenshotSaveDirectory()
                }
            }
            TFButton(title: L("settings.shortcuts.screenshot.saveLocation.choose")) {
                viewModel.chooseScreenshotSaveDirectory()
            }
        }
    }

    private var filteredVocabularyEntries: [VocabularyEntry] {
        viewModel.filteredVocabularyEntries.filter { vocabularyFilter.matches($0.source) }
    }

    @ViewBuilder
    private var vocabularyEmptyActions: some View {
        if vocabularyFilter == .otherApps, vocabularyCount(for: .otherApps) == 0 {
            TFButton(title: L("vocabulary.action.importClaude"), systemImage: "arrow.down.doc") {
                viewModel.importClaudeVocabulary()
            }
            .disabled(viewModel.isSynchronizingVocabulary)
            TFButton(title: L("vocabulary.action.importCodex"), systemImage: "arrow.down.doc") {
                viewModel.importCodexVocabulary()
            }
            .disabled(viewModel.isSynchronizingVocabulary)
        } else {
            TFButton(title: L("vocabulary.action.addFirst"), systemImage: "plus", kind: .primary) {
                editingVocabularyEntry = nil
                newVocabularyTerm = ""
                isAddingVocabulary = true
            }
        }
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
            }
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
                .textFieldStyle(ModelFieldStyle(monospaced: false))
                .foregroundStyle(StudioTheme.textPrimary)
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
                        .isEmpty
                ) {
                    submitVocabularyTerm()
                }
            }
        }
        .padding(32)
        .frame(width: 520)
        .styledGlassBackground(in: Rectangle(), cornerRadius: 0, opaqueFill: StudioTheme.modalSurface)
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
        viewModel.vocabularyEntries.count(where: { filter.matches($0.source) })
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
            [viewModel.llmBaseURL, provider.defaultBaseURL] + provider.endpointPresets.map(\.url)
        )
    }

    private var llmModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.llmModel,
            "gpt-4o-mini",
            "gpt-4.1-mini",
            "gpt-4.1"
        ])
    }

    private var focusedLLMRemoteProvider: LLMRemoteProvider? {
        LLMRemoteProvider.from(providerID: viewModel.focusedModelProvider)
    }

    private var remoteLLMModelSuggestions: [String] {
        guard let provider = focusedLLMRemoteProvider else { return llmModelSuggestions }
        return uniqueSuggestions([viewModel.llmModel] + provider.suggestedModels)
    }

    private var ollamaEndpointSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaBaseURL,
            "http://127.0.0.1:11434",
            "http://localhost:11434"
        ])
    }

    private var ollamaModelSuggestions: [String] {
        uniqueSuggestions([
            viewModel.ollamaModel,
            "qwen2.5:7b",
            "llama3.2:3b",
            "gemma3:4b"
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

    private var focusedProviderConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            ModelDetailHeader(
                title: focusedProviderTitle,
                icon: viewModel.focusedModelProvider,
                connected: focusedProviderConnected,
                backTitle: ModelPageTab.speech.title,
                onBack: { viewModel.isShowingSpeechProviderDetail = false }
            )
            TFFormSection(title: L("models.connection")) {
                focusedProviderForm
                focusedProviderActions
                if viewModel.focusedModelProvider == .localSTT {
                    localSTTStorageRow
                }
            }
        }
    }

    private var focusedProviderConnected: Bool {
        guard let provider = STTProvider.settingsDisplayOrder.first(where: {
            $0.studioProviderID == viewModel.focusedModelProvider
        }) else { return providerIsConfigured(viewModel.focusedModelProvider) }
        return ModelAvailability.speechReason(
            provider, settings: viewModel.modelLibrary.settings, loggedIn: authState.isLoggedIn,
            localModelAvailable: viewModel.isModelAvailable(
                provider == .typefluxOfficial ? .senseVoiceSmall : viewModel.localSTTModel
            ), googleAuthorized: viewModel.googleCloudOAuthAuthorized
        ) == nil
    }

    @ViewBuilder
    private var focusedProviderActions: some View {
        // Language providers use ProviderModelsView; this footer belongs to speech connections.
        let supportsConnection = [StudioModelProviderID.freeSTT, .whisperAPI, .multimodalLLM, .aliCloud,
                       .doubaoRealtime, .googleCloud, .groqSTT, .soniox, .typefluxOfficial]
            .contains(viewModel.focusedModelProvider)
        let canTest = supportsConnection
            && (!viewModel.focusedModelProvider.requiresLoginForConnectionTest || authState.isLoggedIn)
        if canTest || (supportsConnection && viewModel.focusedModelProvider.showsManualSaveButton) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    Spacer(minLength: 8)
                    if canTest {
                        TFButton(title: L("ask.models.test"), isLoading: viewModel.sttConnectionTestState == .testing) {
                            viewModel.testSTTConnection()
                        }
                        .disabled(viewModel.sttConnectionTestState == .testing)
                    }
                    if viewModel.focusedModelProvider.showsManualSaveButton {
                        TFButton(title: L("ask.models.save"), kind: .primary) {
                            viewModel.applyModelConfiguration()
                        }
                    }
                }
                if canTest { connectionTestResultView(viewModel.sttConnectionTestState) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private var localSTTStorageRow: some View {
        ModelFormRow(title: L("settings.models.storagePath")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    Text(viewModel.localSTTStoragePath)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(TFColors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    TFButton(title: L("common.copy"), systemImage: "doc.on.doc", kind: .plain, size: .small,
                             iconOnly: true) { viewModel.copyLocalSTTStoragePath() }
                    TFButton(title: L("settings.models.storagePath"), systemImage: "folder", kind: .plain, size: .small,
                             iconOnly: true) { viewModel.openLocalSTTStorageFolder() }
                }
                TFFootnote(text: viewModel.localSTTStatus)
            }
        }
    }

    private var focusedProviderForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.focusedModelProvider {
            case .typefluxOfficial:
                ModelFormRow(title: L("studio.section.account")) { typefluxOfficialProviderForm }

            case .appleSpeech:
                ModelFormRow(title: L("common.model")) {
                    Text(STTProvider.appleSpeech.displayName).font(.system(size: 13))
                }

            case .freeSTT:
                ModelFormRow(title: L("common.model")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                            TFFootnote(text: L("settings.models.freeSTT.noSources"))
                        } else {
                            TFPopUpButton(
                                title: L("common.model"),
                                options: FreeSTTModelRegistry.suggestedModelNames.map { TFOption($0, $0) },
                                selection: Binding(get: { viewModel.freeSTTModel }, set: viewModel.setFreeSTTModel),
                                width: 320
                            )
                        }
                        TFFootnote(text: L("settings.models.freeSTT.hint"))
                        if !FreeSTTModelRegistry.sources.isEmpty {
                            TFDetailBlock(title: L("settings.models.freeSTT.availableSources"),
                                          content: FreeSTTModelRegistry.sourceSummaryLines().joined(separator: "\n"))
                        }
                    }
                }
                TFDivider.form

            case .localSTT:
                VStack(spacing: 0) {
                    ForEach(LocalSTTModel.displayOrder, id: \.self) { model in
                        localSTTModelOptionCard(model)
                        TFDivider.form
                    }
                }
                .confirmationDialog(
                    localSTTPendingDownload.map {
                        L("settings.models.downloadDialog.title", $0.displayName)
                    } ?? "",
                    isPresented: Binding(
                        get: { localSTTPendingDownload != nil },
                        set: { if !$0 { localSTTPendingDownload = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(L("settings.models.prepareLocalModel")) {
                        if let model = localSTTPendingDownload {
                            viewModel.prepareLocalSTTModel(model)
                            localSTTPendingDownload = nil
                        }
                    }
                    Button(L("common.cancel"), role: .cancel) {
                        localSTTPendingDownload = nil
                    }
                } message: {
                    Text(L("settings.models.downloadDialog.message"))
                }
                .confirmationDialog(
                    localSTTPendingRedownload.map {
                        L("settings.models.redownloadDialog.title", $0.displayName)
                    } ?? "",
                    isPresented: Binding(
                        get: { localSTTPendingRedownload != nil },
                        set: { if !$0 { localSTTPendingRedownload = nil } }
                    ),
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
                        set: { if !$0 { localSTTPendingDelete = nil } }
                    ),
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
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL
                    ),
                    suggestions: whisperEndpointSuggestions,
                    horizontal: true
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: whisperModelSuggestions[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions,
                    horizontal: true
                )
                StudioTextInputCard(
                    label: L("common.apiKey"), placeholder: "sk-...",
                    text: Binding(
                        get: { viewModel.whisperAPIKey }, set: viewModel.setWhisperAPIKey
                    ),
                    secure: true,
                    horizontal: true
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
                        get: { viewModel.ollamaBaseURL }, set: viewModel.setOllamaBaseURL
                    ),
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
                        get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup
                    )
                )
                .toggleStyle(.switch)

            case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek,
                 .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
                llmRemoteProviderForm

            case .typefluxCloud:
                typefluxCloudLLMProviderForm

            case .multimodalLLM:
                VStack(alignment: .leading, spacing: 0) {
                    StudioSuggestedTextInputCard(
                        label: L("settings.models.apiEndpoint"),
                        placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMBaseURL },
                            set: viewModel.setMultimodalLLMBaseURL
                        ),
                        suggestions: multimodalEndpointSuggestions,
                        horizontal: true
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                        text: Binding(
                            get: { viewModel.multimodalLLMModel },
                            set: viewModel.setMultimodalLLMModel
                        ),
                        suggestions: multimodalModelSuggestions,
                        horizontal: true
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.multimodalLLMAPIKey },
                            set: viewModel.setMultimodalLLMAPIKey
                        ), secure: true,
                        horizontal: true
                    ) {
                        if let url = sttProviderAPIKeyURL(.multimodalLLM) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                    TFFootnote(text: L("settings.models.multimodalLLM.audioHint")).padding(.horizontal, 14).padding(.vertical, 8)
                }

            case .aliCloud:
                VStack(alignment: .leading, spacing: 0) {
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: AliCloudASRDefaults.model,
                        text: Binding(
                            get: { viewModel.aliCloudModel },
                            set: viewModel.setAliCloudModel
                        ),
                        suggestions: AliCloudASRDefaults.suggestedModels,
                        horizontal: true
                    )
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(
                            get: { viewModel.aliCloudAPIKey }, set: viewModel.setAliCloudAPIKey
                        ),
                        secure: true,
                        horizontal: true
                    ) {
                        if let url = sttProviderAPIKeyURL(.aliCloud) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                }

            case .doubaoRealtime:
                VStack(alignment: .leading, spacing: 0) {
                    StudioTextInputCard(
                        label: L("settings.models.doubao.appID"), placeholder: "APPID",
                        text: Binding(get: { viewModel.doubaoAppID }, set: viewModel.setDoubaoAppID),
                        horizontal: true
                    )
                    StudioTextInputCard(
                        label: L("settings.models.doubao.resourceID"),
                        placeholder: DoubaoASRDefaults.resourceID,
                        text: Binding(
                            get: { viewModel.doubaoResourceID },
                            set: viewModel.setDoubaoResourceID
                        ),
                        horizontal: true
                    )
                    StudioTextInputCard(
                        label: L("settings.models.doubao.accessToken"), placeholder: "access-token",
                        text: Binding(
                            get: { viewModel.doubaoAccessToken },
                            set: viewModel.setDoubaoAccessToken
                        ), secure: true,
                        horizontal: true
                    ) {
                        TFButton(title: L("settings.models.doubao.docs"), kind: .link, size: .small) {
                            NSWorkspace.shared.open(URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!)
                        }
                    }
                }

            case .googleCloud:
                VStack(alignment: .leading, spacing: 0) {
                    StudioTextInputCard(
                        label: L("settings.models.googleCloud.projectID"), placeholder: "my-gcp-project",
                        text: Binding(
                            get: { viewModel.googleCloudProjectID },
                            set: viewModel.setGoogleCloudProjectID
                        ),
                        horizontal: true
                    )
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: GoogleCloudSpeechDefaults.model,
                        text: Binding(
                            get: { viewModel.googleCloudModel },
                            set: viewModel.setGoogleCloudModel
                        ),
                        suggestions: GoogleCloudSpeechDefaults.suggestedModels,
                        horizontal: true
                    )
                    ModelFormRow(title: "Google OAuth") {
                        HStack(spacing: 8) {
                            TFButton(title: viewModel.googleCloudOAuthAuthorized
                                         ? L("settings.models.googleCloud.oauth.reauthorize")
                                         : L("settings.models.googleCloud.oauth.authorize"),
                                     isLoading: viewModel.isAuthorizingGoogleCloudOAuth) {
                                viewModel.authorizeGoogleCloudOAuth()
                            }
                            .disabled(AppServerConfiguration.googleCloudOAuthClientID.isEmpty)

                            if viewModel.googleCloudOAuthAuthorized {
                                TFButton(title: L("settings.models.googleCloud.oauth.disconnect")) {
                                    viewModel.disconnectGoogleCloudOAuth()
                                }
                            }

                            Spacer()
                        }
                    }
                    TFDivider.form
                }

            case .groqSTT:
                VStack(alignment: .leading, spacing: 0) {
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "gsk_...",
                        text: Binding(get: { viewModel.groqSTTAPIKey }, set: viewModel.setGroqSTTAPIKey),
                        secure: true,
                        horizontal: true
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
                        horizontal: true
                    )
                }

            case .soniox:
                VStack(alignment: .leading, spacing: 0) {
                    StudioTextInputCard(
                        label: L("common.apiKey"), placeholder: "sk-...",
                        text: Binding(get: { viewModel.sonioxAPIKey }, set: viewModel.setSonioxAPIKey),
                        secure: true,
                        horizontal: true
                    ) {
                        if let url = sttProviderAPIKeyURL(.soniox) {
                            apiKeyHelpButton(url: url)
                        }
                    }
                    StudioSuggestedTextInputCard(
                        label: L("common.model"),
                        placeholder: SonioxASRDefaults.model,
                        text: Binding(get: { viewModel.sonioxModel }, set: viewModel.setSonioxModel),
                        suggestions: SonioxASRDefaults.suggestedModels,
                        horizontal: true
                    )
                }
            }
        }
    }

    private var typefluxOfficialProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxOfficial.loginRequired"))
    }

    private var typefluxCloudLLMProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxCloud.loginRequired"))
    }

    private func typefluxLoginRequiredForm(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !authState.isLoggedIn {
                TFNotice(text: message, tone: .warning)
                HStack {
                    Spacer()
                    TFButton(title: L("settings.models.typefluxOfficial.signIn"), systemImage: "person.circle",
                             kind: .primary) {
                        LoginWindowController.shared.show()
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
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFSpinner()
                TFFootnote(text: L("settings.models.testingConnection"))
            }
        case let .success(firstMs, totalMs, preview):
            VStack(alignment: .leading, spacing: 8) {
                TFNotice(text: L("settings.models.connectionSuccess", firstMs, totalMs), tone: .success)
                if !preview.isEmpty {
                    TFDetailBlock(title: L("settings.models.connectionPreview"), content: preview)
                }
            }
        case let .notice(message):
            TFNotice(text: message)
        case let .failure(message):
            TFNotice(text: message, tone: .danger)
        }
    }

    private func localSTTModelOptionCard(_ model: LocalSTTModel) -> some View {
        let isFocused = viewModel.localSTTFocusedModel == model
        let isDownloaded = viewModel.isModelAvailable(model)
        let isActive = viewModel.localSTTModel == model && isDownloaded
        let specs = model.specs

        return ModelFormRow(title: model.displayName) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(specs.summary)
                        .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isActive {
                        TFTag(text: L("settings.models.selected"), tint: TFColors.accent)
                    }
                }
                HStack {
                    Text("\(specs.parameterValue) parameters · \(specs.sizeValue)")
                        .font(.system(size: 12)).foregroundStyle(TFColors.textTertiary)
                    Spacer()
                    localSTTModelDownloadIconButton(model)
                }
                if isFocused, viewModel.isPreparingLocalSTT || !isDownloaded {
                    localSTTModelProgressRow(model)
                    Text(viewModel.localSTTPreparationDetail)
                        .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    if !viewModel.localSTTTransferDetail.isEmpty {
                        Text(viewModel.localSTTTransferDetail)
                            .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectLocalSTTModelCard(model) }
        .contextMenu {
            Button {
                let isAvailable = viewModel.isModelAvailable(model)
                if isAvailable {
                    localSTTPendingRedownload = model
                } else {
                    viewModel.focusLocalSTTModel(model)
                    localSTTPendingDownload = model
                }
            } label: {
                let isAvailable = viewModel.isModelAvailable(model)
                Label(
                    isAvailable ? L("settings.models.redownload") : L("settings.models.prepareLocalModel"),
                    systemImage: isAvailable ? "arrow.clockwise" : "arrow.down"
                )
            }

            // SenseVoice is the system-managed baseline fallback. It can be repaired or
            // re-downloaded, but must not be permanently removed from the app.
            if model != .senseVoiceSmall, viewModel.isModelAvailable(model) {
                Divider()
                Button(role: .destructive) {
                    localSTTPendingDelete = model
                } label: {
                    Label(L("settings.models.deleteModelFiles"), systemImage: "trash")
                }
            }
        }
    }

    private func localSTTModelProgressRow(_ model: LocalSTTModel) -> some View {
        HStack(alignment: .center, spacing: TFMetrics.toolbarSpacing) {
            ProgressView(value: viewModel.localSTTDisplayedPreparationProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(viewModel.localSTTPreparationTint)

            Text(viewModel.localSTTPreparationPercentText)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(TFColors.textSecondary)
                .frame(width: 40, alignment: .trailing)

        }
    }

    private func localSTTModelDownloadIconButton(_ model: LocalSTTModel) -> some View {
        let isDownloaded = viewModel.isModelAvailable(model)
        let title = viewModel.isPreparingLocalSTT
            ? L("settings.models.preparing")
            : (isDownloaded ? L("settings.models.redownload") : L("settings.models.prepareLocalModel"))
        let systemImage = isDownloaded ? "arrow.clockwise" : "arrow.down"

        return TFButton(title: title, systemImage: systemImage, kind: .plain, size: .small, iconOnly: true) {
            guard !viewModel.isPreparingLocalSTT else { return }
            viewModel.focusLocalSTTModel(model)
            if isDownloaded {
                localSTTPendingRedownload = model
            } else {
                localSTTPendingDownload = model
            }
        }
        .disabled(viewModel.isPreparingLocalSTT)
    }

    private func selectLocalSTTModelCard(_ model: LocalSTTModel) {
        viewModel.focusLocalSTTModel(model)
        if !viewModel.isModelAvailable(model) {
            localSTTPendingDownload = model
        }
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
             .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
                && viewModel.googleCloudOAuthAuthorized
        case .groqSTT:
            !viewModel.groqSTTAPIKey.isEmpty
        case .soniox:
            !viewModel.sonioxAPIKey.isEmpty
        case .typefluxOfficial:
            authState.isLoggedIn
        case .typefluxCloud:
            authState.isLoggedIn
        }
    }

    private func apiKeyHelpButton(url: URL) -> some View {
        TFButton(title: L("onboarding.models.getAPIKey"), systemImage: "key", kind: .link, size: .small) {
            NSWorkspace.shared.open(url)
        }
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
        case .soniox:
            URL(string: "https://console.soniox.com/")
        case .doubaoRealtime, .googleCloud, .freeModel, .localModel, .appleSpeech, .typefluxOfficial:
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
        case .openCodeZen:
            URL(string: "https://opencode.ai/auth")
        case .openCodeGo:
            URL(string: "https://opencode.ai/auth")
        case .freeModel, .custom:
            nil
        case .typefluxCloud:
            nil
        }
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
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
        case .soniox:
            STTProvider.soniox.displayName
        case .typefluxOfficial:
            STTProvider.typefluxOfficial.displayName
        case .typefluxCloud:
            LLMRemoteProvider.typefluxCloud.displayName
        }
    }

}

private struct VocabularyTermCard: View {
    let entry: VocabularyEntry
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TFTermTile(title: entry.term, systemImage: "sparkles", image: vocabularySourceLogoImage(for: entry.source),
                   removeTitle: L("common.delete"), onRemove: onDelete)
            .contextMenu {
                Button(L("common.copy"), systemImage: "doc.on.doc", action: onCopy)
                Button(L("common.edit"), systemImage: "pencil", action: onEdit)
                Button(L("common.delete"), systemImage: "trash", role: .destructive, action: onDelete)
            }
    }
}
