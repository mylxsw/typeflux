import AppKit
import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable file_length
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

// swiftlint:disable:next type_body_length
struct StudioView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var imageSettings: AskImageSettingsModel
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var selectedHistoryID: UUID?
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
    @State private var isDirectFeedbackPresented = false
    @State private var feedbackContent = ""
    @State private var feedbackContact = ""
    @State private var feedbackImages: [FeedbackImageAttachment] = []
    @State private var feedbackImageUploadTasks: [FeedbackImageAttachment.ID: Task<Void, Never>] = [:]
    @State private var isSubmittingFeedback = false
    @State private var feedbackSubmissionError: String?
    @State private var agentPane: AgentSettingsPane
    @StateObject private var toolbarSearch = TypefluxSearchState()
    @StateObject private var interfaceStyleObserver: InterfaceStyleObserver
    @State private var launcherPane: LauncherSettingsPane
    @State private var settingsPane: AppSettingsPane

    /// `launcherPane` opens the Launcher page at one of its panes, e.g. the keyword list.
    init(viewModel: StudioViewModel, launcherPane: LauncherSettingsPane = .basics,
         settingsPane: AppSettingsPane = .general, agentPane: AgentSettingsPane = .overview) {
        self.viewModel = viewModel
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
            title: toolbarTitle,
            onSelect: viewModel.navigateFromSidebar,
            onAccountAction: handleAccountAction,
            search: searchScope == nil ? nil : toolbarSearch,
            searchPlaceholder: searchPrompt,
            accountDefaults: viewModel.askToolSettings.defaults,
            toolbarCenter: toolbarSegments,
            toolbarGroups: pageToolbarGroups
        ) { viewportSize in
            let viewportHeight = max(viewportSize.height, 0)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                if viewModel.currentSection == .settings {
                    settingsHeader
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
                height: [.models, .personas, .settings, .account, .vocabulary, .history]
                    .contains(viewModel.currentSection)
                    ? viewportHeight : nil,
                alignment: .top
            )
            .frame(
                minHeight: viewModel.currentSection == .vocabulary ? viewportHeight : nil,
                alignment: .topLeading
            )
            .id(viewModel.currentSection)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: viewModel.currentSection)
        }
        .onChange(of: searchScope) { _ in
            toolbarSearch.focusChanged(false)
            toolbarSearch.query = ""
            viewModel.searchQuery = ""
            viewModel.modelSearchQuery = ""
        }
        .onChange(of: toolbarSearch.query) { query in
            if searchScope?.usesModelQuery == true, viewModel.modelSearchQuery != query {
                viewModel.modelSearchQuery = query
            } else if searchScope?.usesStudioQuery == true, viewModel.searchQuery != query {
                viewModel.searchQuery = query
            }
        }
        .onChange(of: viewModel.searchQuery) { query in
            if searchScope?.usesStudioQuery == true, toolbarSearch.query != query {
                toolbarSearch.query = query
            }
        }
        .onChange(of: viewModel.modelSearchQuery) { query in
            if searchScope?.usesModelQuery == true, toolbarSearch.query != query {
                toolbarSearch.query = query
            }
        }
        .toolbar { libraryPageToolbar }
        .onChange(of: viewModel.currentSection) { _ in selectedHistoryID = nil }
        .onChange(of: viewModel.searchQuery) { _ in selectedHistoryID = nil }
        .onChange(of: viewModel.historyFilter) { _ in selectedHistoryID = nil }
        .onChange(of: viewModel.displayedHistory.map(\.id)) { ids in
            if let selectedHistoryID, !ids.contains(selectedHistoryID) {
                self.selectedHistoryID = nil
            }
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
        .onReceive(viewModel.$directFeedbackRequestID.compactMap(\.self).receive(on: RunLoop.main)) { _ in
            viewModel.directFeedbackRequestID = nil
            openDirectFeedback()
        }
        .onReceive(viewModel.$settingsPaneRequest.compactMap(\.self)) { pane in
            settingsPane = pane
        }
        .onReceive(viewModel.$launcherPaneRequest.compactMap(\.self)) { pane in
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
                set: {
                    if !$0 {
                        llmActivationMissingAPIKeyProviderName = nil
                    }
                }
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
        .sheet(isPresented: $isRecentInputMemoryManagerPresented) {
            RecentInputMemoryManagementView(viewModel: viewModel)
        }
        .confirmationDialog(
            L("agent.mcp.deleteDialog.title"),
            isPresented: Binding(
                get: { mcpServerPendingDeletion != nil },
                set: {
                    if !$0 {
                        mcpServerPendingDeletion = nil
                    }
                }
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
        .sheet(
            isPresented: $isDirectFeedbackPresented,
            onDismiss: cancelAllFeedbackImageUploads
        ) {
            directFeedbackSheet
        }
    }

    private var directFeedbackSheet: some View {
        DirectFeedbackSheet(
            content: $feedbackContent,
            contact: $feedbackContact,
            images: $feedbackImages,
            isSubmitting: isSubmittingFeedback,
            errorMessage: feedbackSubmissionError,
            onAddImages: selectFeedbackImages,
            onRemoveImage: removeFeedbackImage,
            onCancel: {
                cancelAllFeedbackImageUploads()
                isDirectFeedbackPresented = false
            },
            onSubmit: submitDirectFeedback
        )
    }

    private func openDirectFeedback() {
        guard !isDirectFeedbackPresented else { return }
        cancelAllFeedbackImageUploads()
        feedbackContent = ""
        feedbackContact = authState.userProfile?.email ?? ""
        feedbackImages = []
        feedbackImageUploadTasks = [:]
        feedbackSubmissionError = nil
        isSubmittingFeedback = false
        isDirectFeedbackPresented = true
    }

    private func submitDirectFeedback() {
        let content = feedbackContent
        let contact = feedbackContact
        isSubmittingFeedback = true
        feedbackSubmissionError = nil

        Task { @MainActor in
            do {
                let credential = await authState.validSessionCredential()
                let imageURLs: [String]
                do {
                    imageURLs = try FeedbackUploadFlow.submissionImageURLs(
                        for: feedbackImages,
                        submittingAs: FeedbackUploadOwner(credential)
                    )
                } catch let error as FeedbackUploadOwnerError {
                    // Never attach another sign-in's uploads; the user removes
                    // and re-adds them under the current account.
                    for id in error.staleImageIDs {
                        updateFeedbackImage(id: id) { $0.state = .failed(error.localizedDescription) }
                    }
                    throw error
                }
                _ = try await FeedbackAPIService.submit(
                    content: content,
                    contact: contact,
                    imageURLs: imageURLs,
                    token: credential?.accessToken
                )
                isSubmittingFeedback = false
                isDirectFeedbackPresented = false
                feedbackContent = ""
                feedbackContact = ""
                feedbackImages = []
                viewModel.showToast(L("feedback.toast.submitted"))
            } catch {
                isSubmittingFeedback = false
                feedbackSubmissionError = error.localizedDescription
            }
        }
    }

    private func selectFeedbackImages() {
        let remainingSlots = max(0, 4 - feedbackImages.count)
        guard remainingSlots > 0 else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .webP, .gif]

        guard panel.runModal() == .OK else { return }
        let selectedURLs = Array(panel.urls.prefix(remainingSlots))
        for url in selectedURLs {
            enqueueFeedbackImageUpload(from: url)
        }
    }

    private func removeFeedbackImage(id: FeedbackImageAttachment.ID) {
        feedbackImageUploadTasks.removeValue(forKey: id)?.cancel()
        feedbackImages.removeAll { $0.id == id }
    }

    private func enqueueFeedbackImageUpload(from url: URL) {
        let id = UUID()
        feedbackImages.append(
            FeedbackImageAttachment(
                id: id,
                filename: url.lastPathComponent,
                state: .preparing
            )
        )

        let task = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let prepared = try FeedbackImageProcessor.prepare(url: url)
                try Task.checkCancellation()
                await updateFeedbackImage(id: id) { image in
                    image.filename = prepared.filename
                    image.thumbnail = prepared.thumbnail
                    image.state = .uploading
                }
                try Task.checkCancellation()

                // The ticket and the PUT carry the same account token; the
                // image remembers which sign-in uploaded it.
                let credential = await AuthState.shared.validSessionCredential()
                let imageURL = try await FeedbackUploadFlow.upload(prepared, credential: credential)

                await updateFeedbackImage(id: id) { image in
                    image.state = .uploaded(imageURL)
                    image.uploadOwner = FeedbackUploadOwner(credential)
                }
            } catch is CancellationError {
                await clearFeedbackImageUploadTask(id: id)
                return
            } catch {
                guard !Task.isCancelled else {
                    await clearFeedbackImageUploadTask(id: id)
                    return
                }
                await updateFeedbackImage(id: id) { image in
                    image.state = .failed(error.localizedDescription)
                }
            }
            await clearFeedbackImageUploadTask(id: id)
        }
        feedbackImageUploadTasks[id] = task
    }

    @MainActor
    private func updateFeedbackImage(
        id: FeedbackImageAttachment.ID,
        mutate: (inout FeedbackImageAttachment) -> Void
    ) {
        guard let index = feedbackImages.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&feedbackImages[index])
    }

    @MainActor
    private func clearFeedbackImageUploadTask(id: FeedbackImageAttachment.ID) {
        feedbackImageUploadTasks.removeValue(forKey: id)
    }

    @MainActor
    private func cancelAllFeedbackImageUploads() {
        feedbackImageUploadTasks.values.forEach { $0.cancel() }
        feedbackImageUploadTasks = [:]
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

    private var searchScope: SettingsSearchScope? {
        .resolve(section: viewModel.currentSection, modelTab: viewModel.modelPageTab,
                 providerDetail: viewModel.isShowingModelProviderDetail, agentPane: agentPane,
                 launcherPane: launcherPane)
    }

    private var searchPrompt: String {
        switch searchScope {
        case .skills: L("agent.skills.search")
        case .memory: L("agent.memory.search")
        case .keywords: L("ask.settings.keywords.search")
        default: viewModel.currentSection.searchPlaceholder
        }
    }

    private var toolbarTitle: String {
        switch viewModel.currentSection {
        case .agent: viewModel.currentSection.heading + " · " + agentPane.title
        case .launcher: viewModel.currentSection.heading + " · " + launcherPane.title
        case .models:
            if viewModel.isShowingSpeechProviderDetail {
                focusedProviderTitle
            } else if let id = viewModel.selectedLanguageProviderID,
                      let provider = viewModel.modelLibrary.providers.first(where: { $0.id == id }) {
                provider.name
            } else {
                StudioSection.models.title
            }
        default: viewModel.currentSection.heading
        }
    }

    private var toolbarSegments: AnyView? {
        if viewModel.currentSection == .models {
            return AnyView(TypefluxSegmentedControl(StudioSection.models.title,
                                                    selection: Binding(
                                                        get: { viewModel.modelPageTab },
                                                        set: viewModel.selectModelPageTab
                                                    )) {
                    ForEach(ModelPageTab.allCases) { tab in
                        Text(tab.title).tag(tab).accessibilityIdentifier("studio.models.tab.\(tab.rawValue)")
                    }
                }.fixedSize())
        }
        if viewModel.currentSection.isVoiceInput {
            return AnyView(TypefluxSegmentedControl(viewModel.currentSection.title,
                                                    selection: Binding(
                                                        get: { viewModel.currentSection },
                                                        set: viewModel.navigate
                                                    )) {
                    ForEach(StudioSection.voiceInputCases) { section in
                        Text(section.title + (viewModel.voiceInputTabCount(for: section).map { " \($0)" } ?? ""))
                            .tag(section)
                    }
                }.fixedSize())
        }
        return nil
    }

    private var pageToolbarGroups: [TypefluxToolbarGroup] {
        if viewModel.currentSection == .vocabulary {
            return [TypefluxToolbarGroup(id: "vocabulary", actions: [
                TypefluxToolbarAction(id: "vocabulary.add", title: L("vocabulary.action.newWord"),
                                      systemImage: "plus", perform: beginAddingVocabulary),
                TypefluxToolbarAction(id: "vocabulary.import", title: L("vocabulary.action.importFile"),
                                      systemImage: "arrow.down.doc", isEnabled: !viewModel.isSynchronizingVocabulary,
                                      perform: viewModel.importVocabulary)
            ])]
        }
        if viewModel.currentSection == .history {
            var actions: [TypefluxToolbarAction] = []
            actions.append(TypefluxToolbarAction(id: "history.back", title: L("history.action.back"),
                                                  systemImage: "chevron.left", isEnabled: selectedHistoryID != nil) {
                selectedHistoryID = nil
            })
            actions.append(TypefluxToolbarAction(id: "history.export", title: L("history.action.exportMarkdown"),
                                                 systemImage: "square.and.arrow.up", perform: viewModel.exportHistory))
            actions.append(TypefluxToolbarAction(id: "history.clear", title: L("common.clear"), systemImage: "trash",
                                                 role: .destructive) { showingClearHistoryConfirmation = true })
            return [TypefluxToolbarGroup(id: "history", actions: actions)]
        }
        guard viewModel.currentSection == .models, viewModel.modelPageTab == .providers,
              !viewModel.isShowingModelProviderDetail else { return [] }
        return [TypefluxToolbarGroup(id: "models", actions: [
            TypefluxToolbarAction(id: "models.addProvider", title: L("models.addEndpoint"), systemImage: "plus") {
                viewModel.isAddingModelEndpoint = true
            }
        ])]
    }

    @ToolbarContentBuilder
    private var libraryPageToolbar: some ToolbarContent {
        if viewModel.currentSection == .vocabulary {
            ToolbarItem(placement: .primaryAction) {
                TypefluxSegmentedControl(L("vocabulary.table.source"), selection: $vocabularyFilter) {
                    ForEach(VocabularyFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }
                .fixedSize()
                .accessibilityIdentifier("vocabulary.sourceFilter")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("vocabulary.action.export"), action: viewModel.exportVocabulary)
                    Divider()
                    Button(L("vocabulary.action.importClaude"), action: viewModel.importClaudeVocabulary)
                    Button(L("vocabulary.action.importCodex"), action: viewModel.importCodexVocabulary)
                } label: { Label(L("vocabulary.action.more"), systemImage: "ellipsis") }
                    .disabled(viewModel.isSynchronizingVocabulary)
                    .help(L("vocabulary.action.more"))
                    .accessibilityIdentifier("vocabulary.transferMenu")
            }
        }
        if viewModel.currentSection == .history {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("history.filter.title"), selection: $viewModel.historyFilter) {
                        ForEach(HistorySettingsFilter.allCases) { filter in Text(filter.title).tag(filter) }
                    }
                    Divider()
                    Picker(L("history.keep.title"), selection: Binding(
                        get: { viewModel.historyRetentionPolicy }, set: viewModel.setHistoryRetentionPolicy
                    )) {
                        ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                } label: { Label(L("history.filter.title"), systemImage: "line.3.horizontal.decrease") }
                    .help(viewModel.historyFilter.title)
                    .accessibilityLabel(L("history.filter.title"))
                    .accessibilityIdentifier("history.filterMenu")
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
            historyPage
        case .settings:
            settingsPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .agent:
            agentPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .launcher:
            launcherPage(compact: SettingsPaneMetrics.isCompact(contentWidth: viewportWidth))
        case .account:
            AccountView(authState: AuthState.shared) {
                viewModel.navigate(to: .home)
            }
        }
    }

    private func homePage(viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioOverviewPanel(
                width: viewportWidth,
                completionRate: viewModel.statsCompletionRate,
                transcriptionMinutesText: viewModel.transcriptionMinutesText,
                totalCharacters: viewModel.statsTotalCharacters,
                savedMinutes: viewModel.statsSavedMinutes,
                averagePaceWPM: viewModel.statsAveragePaceWPM
            )

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
                    viewModel.displayedHistory.prefix(StudioTheme.Count.homeRecentRecords)
                )
            )
        }
    }

    private func modelsPage(viewportHeight: CGFloat) -> some View {
        ModelSettingsPage(viewModel: viewModel, library: viewModel.modelLibrary) {
            focusedProviderConfigurationPanel
        }
        .frame(height: viewportHeight, alignment: .top)
    }

    private var personasPage: some View {
        StudioPersonaLibraryView(viewModel: viewModel) { persona in
            viewModel.personaPendingDeletion = persona
        }
    }

    private var historyPage: some View {
        HistorySettingsPage(viewModel: viewModel, selectedID: $selectedHistoryID)
    }

    private var vocabularyPage: some View {
        VocabularySettingsPage(viewModel: viewModel, filter: vocabularyFilter, onAdd: beginAddingVocabulary) { entry in
            editingVocabularyEntry = entry
            newVocabularyTerm = entry.term
            isAddingVocabulary = false
        }
    }

    private var settingsHeader: some View {
        TypefluxSegmentedControl(StudioSection.settings.title, selection: $settingsPane) {
            ForEach(AppSettingsPane.allCases) { pane in
                Text(pane.title).tag(pane)
                    .accessibilityIdentifier("studio.settings.tab." + pane.rawValue)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func settingsPage(compact: Bool) -> some View {
        switch settingsPane {
        case .general:
            GeneralSettingsView(viewModel: viewModel) { isRecentInputMemoryManagerPresented = true }
        case .hotkeys:
            HotkeySettingsView(viewModel: viewModel, settingsStore: viewModel.askToolSettings, compact: compact)
        case .appearance:
            AppearanceSettingsView(viewModel: viewModel)
        case .advanced:
            AdvancedSettingsView(viewModel: viewModel)
        }
    }

    // MARK: - Agent Page

    private func agentPage(compact: Bool) -> some View {
        SettingsPaneLayout(sections: AgentSettingsPane.sections, selection: $agentPane, compact: compact,
                           status: agentPaneStatus) {
            if agentPane == .mcpServers {
                AgentPaneHeader(symbol: AgentCapability.mcpServers.symbol, title: AgentCapability.mcpServers.title) {
                    if !viewModel.mcpServers.isEmpty {
                        Button { beginMCPImport() } label: {
                            Label(L("agent.mcp.import.action"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            viewModel.beginAddMCPServer()
                            isMCPServerDialogPresented = true
                        } label: {
                            Label(L("agent.mcp.addServer"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                agentMCPServersTabContent
            } else {
                AskToolsSettingsView(
                    settings: viewModel.askToolSettings,
                    imageSettingsModel: imageSettings,
                    searchQuery: $toolbarSearch.query,
                    pane: agentPane,
                    onNavigate: { agentPane = $0 },
                    onStatusesChange: { agentStatuses = $0 }
                )
                // Rebuild per pane so each pane reloads its values when shown.
                .id(agentPane)
            }
        }
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
        SettingsPaneLayout(sections: LauncherSettingsPane.sections, selection: $launcherPane, compact: compact) {
            LauncherSettingsView(
                settings: viewModel.askToolSettings, pane: launcherPane,
                searchQuery: $toolbarSearch.query,
                clipboardHistory: SettingsWindowController.shared.clipboardHistoryStore,
                onEditShortcut: {
                    settingsPane = .hotkeys
                    viewModel.navigate(to: .settings)
                }
            )
            .id(launcherPane)
        }
    }

    private var filteredMCPServers: [MCPServerConfig] {
        let query = toolbarSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.mcpServers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || mcpTransportDetail(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder private var agentMCPServersTabContent: some View {
        if viewModel.mcpServers.isEmpty {
            StudioCard(padding: 0) {
                AgentEmptyState(
                    symbol: "server.rack",
                    title: L("agent.mcp.emptyTitle"),
                    message: L("agent.mcp.emptyMessage")
                ) {
                    Button {
                        viewModel.beginAddMCPServer()
                        isMCPServerDialogPresented = true
                    } label: {
                        Label(L("agent.mcp.addServer"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { beginMCPImport() } label: {
                        Label(L("agent.mcp.import.action"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                StudioCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if filteredMCPServers.isEmpty {
                            AgentSettingsEmptyRow(text: L("personas.redesign.noResults", toolbarSearch.query))
                        }
                        ForEach(Array(filteredMCPServers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { ModelRowDivider(leading: 66) }
                            mcpServerRow(server)
                        }
                    }
                }
                Text(L("agent.mcp.listHint")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }

    private func mcpServerRow(_ server: MCPServerConfig) -> some View {
        let status = MCPServerStatusPresentation(enabled: server.enabled, result: viewModel.mcpServerTestResults[server.id])
        return VStack(alignment: .leading, spacing: 0) {
            AgentSettingsRow(
                icon: "server.rack",
                title: server.name.isEmpty ? L("agent.mcp.untitled") : server.name,
                subtitle: mcpTransportDetail(for: server),
                badge: mcpTransportLabel(for: server),
                subtitleLineLimit: 1
            ) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        if status.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(status.color).frame(width: 7, height: 7)
                        }
                        Text(status.label).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                    }
                    .fixedSize()

                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { viewModel.updateMCPServerEnabled(id: server.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(server.name)

                    Menu {
                        mcpServerMenuItems(server)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                    .accessibilityLabel(L("agent.mcp.more"))
                }
            }

            if case let .failure(message)? = viewModel.mcpServerTestResults[server.id] {
                Text(message).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 12)
            } else if case let .success(tools)? = viewModel.mcpServerTestResults[server.id], !tools.isEmpty {
                Text(L("agent.mcp.toolList", tools.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                    .padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.beginEditMCPServer(server)
            isMCPServerDialogPresented = true
        }
        .contextMenu { mcpServerMenuItems(server) }
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
                .background(TypefluxColor.controlBackground.color,
                            in: RoundedRectangle(
                                cornerRadius: TypefluxRadius.textField.value(for: .classic),
                                style: .continuous
                            ))
                .overlay(RoundedRectangle(
                    cornerRadius: TypefluxRadius.textField.value(for: .classic),
                    style: .continuous
                )
                .strokeBorder(TypefluxColor.separator.color))
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
                Button(L("common.cancel")) { isMCPImportPresented = false }.buttonStyle(.bordered)
                Button(L("agent.mcp.import.confirm")) {
                    viewModel.importMCPServers(servers)
                    isMCPImportPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(servers.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(TypefluxColor.windowBackground.color)
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

    private func beginAddingVocabulary() {
        editingVocabularyEntry = nil
        newVocabularyTerm = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isAddingVocabulary = true
    }

    private var vocabularyAddSheet: some View {
        VocabularyTermSheet(term: $newVocabularyTerm, isEditing: editingVocabularyEntry != nil,
                            onCancel: dismissVocabularySheet, onSave: submitVocabularyTerm)
    }

    private func dismissVocabularySheet() {
        editingVocabularyEntry = nil
        newVocabularyTerm = ""
        isAddingVocabulary = false
    }

    private func submitVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if let editingVocabularyEntry {
            viewModel.updateVocabularyEntry(id: editingVocabularyEntry.id, term: term)
        } else {
            viewModel.addVocabularyTerm(term)
        }
        vocabularyFilter = .all
        viewModel.searchQuery = ""
        dismissVocabularySheet()
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

    private var parameterCard: some View {
        StudioCard {
            StudioSectionTitle(title: L("settings.models.configuration"))
            if viewModel.modelDomain == .stt {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.endpoint"),
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: Binding(
                        get: { viewModel.whisperBaseURL }, set: viewModel.setWhisperBaseURL
                    ),
                    suggestions: whisperEndpointSuggestions
                )
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.model"),
                    placeholder: whisperModelSuggestions[0],
                    text: Binding(get: { viewModel.whisperModel }, set: viewModel.setWhisperModel),
                    suggestions: whisperModelSuggestions
                )
            } else {
                if viewModel.llmProvider == .ollama {
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
                        text: Binding(
                            get: { viewModel.ollamaModel }, set: viewModel.setOllamaModel
                        ),
                        suggestions: ollamaModelSuggestions
                    )
                    Toggle(
                        L("settings.models.ollama.autoSetup"),
                        isOn: Binding(
                            get: { viewModel.ollamaAutoSetup }, set: viewModel.setOllamaAutoSetup
                        )
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
                        secure: true
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
                            StudioTheme.Colors.actionCardCool
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
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
                action: secondaryAction
            )
            StudioButton(
                title: primaryButtonTitle, systemImage: nil, variant: .primary,
                action: primaryAction
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
                            onPlayAudio: {
                                viewModel.playAudio(id: record.id)
                            },
                            isAudioPlaying: viewModel.playingAudioRecordID == record.id,
                            onDelete: {
                                viewModel.deleteHistoryRecord(id: record.id)
                            },
                            onRetry: {
                                viewModel.retryHistoryRecord(id: record.id)
                            }
                        )
                        if record.id != records.last?.id {
                            Divider().overlay(
                                StudioTheme.border.opacity(StudioTheme.Opacity.listDivider)
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
            viewModel.sttProvider == .appleSpeech || viewModel.sttProvider == .localModel
        case .llm:
            viewModel.llmProvider == .ollama
        }
    }

    private func architectureModeButton(title: String, subtitle: String, isActive: Bool)
        -> some View {
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
                            height: StudioTheme.ControlSize.selectionIndicatorInner
                        )
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
                    ? OpenAIAudioModelCatalog.defaultWhisperModel(
                        forEndpoint: viewModel.whisperBaseURL
                    ) : viewModel.whisperModel
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
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
            )
        default:
            if let providerID = StudioModelProviderID(rawValue: card.id),
               let provider = LLMRemoteProvider.from(providerID: providerID) {
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
            case .soniox:
                .soniox
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
            sttModelProviderCards
        case .llm:
            llmModelProviderCards
        }
    }

    private var sttModelProviderCards: [StudioModelCard] {
        var cards = [
            StudioModelCard(
                id: StudioModelProviderID.typefluxOfficial.rawValue,
                name: STTProvider.typefluxOfficial.displayName,
                summary: L("settings.models.card.typefluxOfficial.summary"),
                badge: L("settings.models.badge.official"),
                metadata: L("settings.models.builtInDefaultModel"),
                isSelected: viewModel.sttProvider == .typefluxOfficial,
                isMuted: false,
                actionTitle: L("settings.models.useTypefluxOfficial")
            )
        ]

        if !FreeSTTModelRegistry.suggestedModelNames.isEmpty {
            cards.append(
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
                )
            )
        }

        cards.append(
            contentsOf: [
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
                    id: StudioModelProviderID.aliCloud.rawValue,
                    name: STTProvider.aliCloud.displayName,
                    summary: L("settings.models.card.aliCloud.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.aliCloudModel,
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
                StudioModelCard(
                    id: StudioModelProviderID.googleCloud.rawValue,
                    name: STTProvider.googleCloud.displayName,
                    summary: L("settings.models.card.googleCloud.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: L("settings.models.googleCloud.streaming"),
                    isSelected: viewModel.sttProvider == .googleCloud,
                    isMuted: false,
                    actionTitle: L("settings.models.useGoogleCloud")
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
                    id: StudioModelProviderID.groqSTT.rawValue,
                    name: STTProvider.groq.displayName,
                    summary: L("settings.models.card.groq.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.groqSTTModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.groqSTTModel,
                    isSelected: viewModel.sttProvider == .groq,
                    isMuted: false,
                    actionTitle: L("settings.models.useGroq")
                ),
                StudioModelCard(
                    id: StudioModelProviderID.soniox.rawValue,
                    name: STTProvider.soniox.displayName,
                    summary: L("settings.models.card.soniox.summary"),
                    badge: L("settings.models.badge.api"),
                    metadata: viewModel.sonioxModel.isEmpty
                        ? L("settings.models.modelNotConfigured") : viewModel.sonioxModel,
                    isSelected: viewModel.sttProvider == .soniox,
                    isMuted: false,
                    actionTitle: L("settings.models.useSoniox")
                )
            ]
        )

        return cards
    }

    private var llmModelProviderCards: [StudioModelCard] {
        var cards = [
            StudioModelCard(
                id: LLMRemoteProvider.typefluxCloud.studioProviderID.rawValue,
                name: LLMRemoteProvider.typefluxCloud.displayName,
                summary: L("settings.models.card.typefluxCloud.summary"),
                badge: L("settings.models.badge.official"),
                metadata: L("settings.models.builtInDefaultModel"),
                isSelected: viewModel.llmProvider == .openAICompatible
                    && viewModel.llmRemoteProvider == .typefluxCloud,
                isMuted: false,
                actionTitle: L("settings.models.useTypefluxCloud")
            )
        ]

        var standardCards = LLMRemoteProvider.settingsDisplayOrder
            .filter { $0 != .typefluxCloud && $0 != .custom }
            .filter { $0 != .freeModel || !FreeLLMModelRegistry.suggestedModelNames.isEmpty }
            .map { provider in
                (
                    name: provider.displayName,
                    card: makeLLMRemoteProviderCard(
                        provider,
                        badge: provider == .freeModel ? L("settings.models.badge.free") : nil
                    )
                )
            }

        standardCards.append((
            name: LLMProvider.ollama.displayName,
            card: StudioModelCard(
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
        ))
        standardCards.sort { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        cards.append(contentsOf: standardCards.map(\.card))

        let customRemoteProviders = LLMRemoteProvider.settingsDisplayOrder.filter { $0 == .custom }
        cards.append(contentsOf: customRemoteProviders.map { makeLLMRemoteProviderCard($0) })

        return cards
    }

    private func makeLLMRemoteProviderCard(
        _ provider: LLMRemoteProvider,
        badge: String? = nil
    ) -> StudioModelCard {
        let resolvedBadge = badge ?? (
            provider.apiStyle == .openAICompatible
                ? L("settings.models.badge.api") : L("settings.models.badge.native")
        )

        return StudioModelCard(
            id: provider.studioProviderID.rawValue,
            name: provider.displayName,
            summary: L("settings.models.card.\(provider.rawValue).summary"),
            badge: resolvedBadge,
            metadata: metadata(for: provider),
            isSelected: viewModel.llmProvider == .openAICompatible
                && viewModel.llmRemoteProvider == provider,
            isMuted: false,
            actionTitle: L("settings.models.useRemote")
        )
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
                                        StudioTheme.Typography.sectionTitle, weight: .semibold
                                    )
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
                            fill: modelOverviewModeFill
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
                        variant: .secondary
                    ) {
                        viewModel.focusModelProvider(activeModelProviderID)
                    }
                }
            }
        }
    }

    private var focusedProviderConfigurationPanel: some View {
        TypefluxForm {
            ModelDetailHeader(
                title: focusedProviderTitle,
                icon: viewModel.focusedModelProvider,
                connected: focusedProviderConnected,
                backTitle: viewModel.modelPageTab.title,
                onBack: { viewModel.isShowingSpeechProviderDetail = false }
            )
            TypefluxFormSection(L("models.connection")) {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    if canTest {
                        SettingsActionButton(title: L("ask.models.test"),
                                             isLoading: viewModel.sttConnectionTestState == .testing) {
                            viewModel.testSTTConnection()
                        }
                    }
                    if viewModel.focusedModelProvider.showsManualSaveButton {
                        SettingsActionButton(title: L("ask.models.save"), primary: true) {
                            viewModel.applyModelConfiguration()
                        }
                    }
                }
                if canTest { connectionTestResultView(viewModel.sttConnectionTestState) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private var localSTTStorageRow: some View {
        ModelFormRow(title: L("settings.models.storagePath")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(viewModel.localSTTStoragePath)
                        .font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { viewModel.copyLocalSTTStoragePath() } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(L("common.copy"))
                    Button { viewModel.openLocalSTTStorageFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(L("settings.models.storagePath"))
                }
                .buttonStyle(.plain)
                Text(viewModel.localSTTStatus)
                    .font(.body).foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var focusedProviderForm: some View {
        switch viewModel.focusedModelProvider {
        case .typefluxOfficial:
            ModelFormRow(title: L("studio.section.account")) { typefluxOfficialProviderForm }

        case .appleSpeech:
            ModelFormRow(title: L("common.model")) {
                Text(STTProvider.appleSpeech.displayName).font(.body)
            }

        case .freeSTT:
            ModelFormRow(title: L("common.model")) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                        Text(L("settings.models.freeSTT.noSources"))
                            .font(.subheadline)
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
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.textSecondary)

                    if !FreeSTTModelRegistry.sources.isEmpty {
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                            Text(L("settings.models.freeSTT.availableSources"))
                                .font(.subheadline)
                                .foregroundStyle(StudioTheme.textSecondary)
                            ForEach(FreeSTTModelRegistry.sourceSummaryLines(), id: \.self) { line in
                                Text(line)
                                    .font(.body.monospaced())
                                    .foregroundStyle(StudioTheme.textTertiary)
                            }
                        }
                    }
                }
            }

        case .localSTT:
            List(LocalSTTModel.displayOrder, id: \.self, selection: Binding<LocalSTTModel?>(
                get: { viewModel.localSTTFocusedModel },
                set: {
                    if let model = $0 {
                        selectLocalSTTModelCard(model)
                    }
                }
            )) { model in
                localSTTModelOptionCard(model).tag(model)
            }
            .listStyle(.inset).frame(height: 420)
            .confirmationDialog(
                localSTTPendingDownload.map {
                    L("settings.models.downloadDialog.title", $0.displayName)
                } ?? "",
                isPresented: Binding(
                    get: { localSTTPendingDownload != nil },
                    set: {
                        if !$0 {
                            localSTTPendingDownload = nil
                        }
                    }
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
                    set: {
                        if !$0 {
                            localSTTPendingRedownload = nil
                        }
                    }
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
                    set: {
                        if !$0 {
                            localSTTPendingDelete = nil
                        }
                    }
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
            Group {
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
                Text(L("settings.models.multimodalLLM.audioHint"))
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
            }

        case .aliCloud:
            Group {
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
            Group {
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
                    Button {
                        NSWorkspace.shared.open(
                            URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!
                        )
                    } label: {
                        Text(L("settings.models.doubao.docs"))
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

        case .googleCloud:
            Group {
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
                        SettingsActionButton(
                            title: viewModel.googleCloudOAuthAuthorized
                                ? L("settings.models.googleCloud.oauth.reauthorize")
                                : L("settings.models.googleCloud.oauth.authorize"),
                            isLoading: viewModel.isAuthorizingGoogleCloudOAuth,
                            isDisabled: AppServerConfiguration.googleCloudOAuthClientID.isEmpty
                        ) {
                            viewModel.authorizeGoogleCloudOAuth()
                        }

                        if viewModel.googleCloudOAuthAuthorized {
                            SettingsActionButton(
                                title: L("settings.models.googleCloud.oauth.disconnect")
                            ) {
                                viewModel.disconnectGoogleCloudOAuth()
                            }
                        }

                        Spacer()
                    }
                }
            }

        case .groqSTT:
            Group {
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
            Group {
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

    private var typefluxOfficialProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxOfficial.loginRequired"))
    }

    private var typefluxCloudLLMProviderForm: some View {
        typefluxLoginRequiredForm(message: L("settings.models.typefluxCloud.loginRequired"))
    }

    private func typefluxLoginRequiredForm(message: String) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            if !authState.isLoggedIn {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.warning)

                    HStack {
                        Spacer()

                        SettingsActionButton(
                            title: L("settings.models.typefluxOfficial.signIn"),
                            symbol: "person.circle",
                            primary: true
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
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        case let .success(firstMs, totalMs, preview):
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(StudioTheme.success)
                    Text(L("settings.models.connectionSuccess", firstMs, totalMs))
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(StudioTheme.Spacing.small)
                        .background(
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous
                            )
                            .fill(StudioTheme.controlSurface)
                        )
                }
            }
        case let .notice(message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .failure(message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(StudioTheme.danger)
                Text(message)
                    .font(.subheadline)
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
                    if viewModel.modelDomain == .llm, viewModel.llmProvider == .ollama {
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
            StudioCard(
                padding: StudioTheme.Insets.cardCompact,
                showsShadow: true,
                isHighlighted: isFocused,
                isDimmed: !isFocused,
                texture: .softWaves
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.xSmall) {
                        RoundedRectangle(
                            cornerRadius: StudioTheme.CornerRadius.large, style: .continuous
                        )
                        .fill(StudioTheme.modelProviderIconPlate)
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
                                height: StudioTheme.ControlSize.modelProviderStatusDot
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
                                fill: StudioTheme.success.opacity(0.12)
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
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

    @ViewBuilder
    private func providerIconView(for provider: StudioModelProviderID, isFocused: Bool) -> some View {
        if provider.usesTypefluxBranding {
            TypefluxLogoBadge(
                size: 28,
                symbolSize: 14,
                backgroundShape: .circle,
                showsBorder: true
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
                        size: StudioTheme.ControlSize.modelProviderBadgeSymbol, weight: .semibold
                    )
                )
                .foregroundStyle(isFocused ? StudioTheme.accent : StudioTheme.modelProviderFallbackSymbol)
        }
    }

    private func providerLogoImage(for provider: StudioModelProviderID) -> NSImage? {
        ModelProviderIcon.image(for: provider)
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
                        .font(.subheadline).foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isActive {
                        Text(L("settings.models.selected")).font(.subheadline)
                            .foregroundStyle(TypefluxColor.accent.color)
                    }
                }
                HStack {
                    Text("\(specs.parameterValue) parameters · \(specs.sizeValue)")
                        .font(.subheadline).foregroundStyle(StudioTheme.textTertiary)
                    Spacer()
                    localSTTModelDownloadIconButton(model)
                }
                if isFocused, viewModel.isPreparingLocalSTT || !isDownloaded {
                    localSTTModelProgressRow(model)
                    Text(viewModel.localSTTPreparationDetail)
                        .font(.subheadline).foregroundStyle(StudioTheme.textSecondary)
                    if !viewModel.localSTTTransferDetail.isEmpty {
                        Text(viewModel.localSTTTransferDetail)
                            .font(.subheadline).foregroundStyle(StudioTheme.textSecondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
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

    private func localSTTModelProgressRow(_: LocalSTTModel) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
            ProgressView(value: viewModel.localSTTDisplayedPreparationProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(viewModel.localSTTPreparationTint)

            Text(viewModel.localSTTPreparationPercentText)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func localSTTModelDownloadIconButton(_ model: LocalSTTModel) -> some View {
        let isDownloaded = viewModel.isModelAvailable(model)
        let title = viewModel.isPreparingLocalSTT
            ? L("settings.models.preparing")
            : (isDownloaded ? L("settings.models.redownload") : L("settings.models.prepareLocalModel"))
        let systemImage = isDownloaded ? "arrow.clockwise" : "arrow.down"

        return Button {
            guard !viewModel.isPreparingLocalSTT else { return }
            viewModel.focusLocalSTTModel(model)
            if isDownloaded {
                localSTTPendingRedownload = model
            } else {
                localSTTPendingDownload = model
            }
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(viewModel.isPreparingLocalSTT ? StudioTheme.textTertiary : StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isPreparingLocalSTT)
        .help(title)
        .accessibilityLabel(title)
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
                        forEndpoint: viewModel.whisperBaseURL
                    ) : viewModel.whisperModel
            )
        case .ollama:
            viewModel.applyModelConfiguration(shouldShowToast: false)
            viewModel.setLLMModelSelection(
                .ollama,
                suggestedModel: viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
            )
            viewModel.prepareOllamaModel()
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
                    ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel
            )
        case .aliCloud:
            viewModel.setSTTProvider(.aliCloud)
        case .doubaoRealtime:
            viewModel.setSTTProvider(.doubaoRealtime)
        case .googleCloud:
            viewModel.setSTTProvider(.googleCloud)
        case .groqSTT:
            viewModel.setSTTProvider(.groq)
        case .soniox:
            viewModel.setSTTProvider(.soniox)
        case .typefluxOfficial:
            viewModel.setSTTProvider(.typefluxOfficial)
        case .typefluxCloud:
            viewModel.setLLMRemoteProvider(.typefluxCloud)
        }
    }

    private func iconName(for provider: StudioModelProviderID) -> String {
        ModelProviderIcon.symbol(for: provider)
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
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
        case .soniox:
            L("settings.models.overview.soniox")
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
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
        case .soniox:
            STTProvider.soniox.displayName
        case .typefluxOfficial:
            STTProvider.typefluxOfficial.displayName
        }
    }

    private var modelOverviewModePill: String {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            L("settings.models.mode.local")
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .soniox, .typefluxOfficial,
             .typefluxCloud:
            L("settings.models.mode.remote")
        }
    }

    private var modelOverviewModeTone: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            StudioTheme.success
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .soniox, .typefluxOfficial,
             .typefluxCloud:
            StudioTheme.accent
        }
    }

    private var modelOverviewModeFill: Color {
        switch activeModelProviderID {
        case .appleSpeech, .localSTT, .ollama:
            StudioTheme.success.opacity(0.12)
        case .freeSTT, .whisperAPI, .freeModel, .customLLM, .openRouter, .openAI, .anthropic,
             .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo,
             .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groqSTT, .soniox, .typefluxOfficial,
             .typefluxCloud:
            StudioTheme.accentSoft
        }
    }

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

    private var modelOverviewExtraPill: String? {
        if viewModel.modelDomain == .stt {
            // Apple Speech fallback is intentionally hidden from all settings summaries.
            // return viewModel.appleSpeechFallback
            //     ? L("settings.models.fallback.enabled") : L("settings.models.fallback.off")
            return nil
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
                    forEndpoint: viewModel.whisperBaseURL
                ) : viewModel.whisperModel
        case .ollama:
            viewModel.ollamaModel.isEmpty ? "qwen2.5:7b" : viewModel.ollamaModel
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi,
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
            viewModel.llmModel.isEmpty
                ? activeLLMRemoteProvider.defaultModel : viewModel.llmModel
        case .multimodalLLM:
            viewModel.multimodalLLMModel.isEmpty
                ? OpenAIAudioModelCatalog.multimodalModels[0] : viewModel.multimodalLLMModel
        case .aliCloud:
            viewModel.aliCloudModel
        case .doubaoRealtime:
            L("settings.models.doubao.productName")
        case .googleCloud:
            viewModel.googleCloudModel.isEmpty ? GoogleCloudSpeechDefaults.model : viewModel.googleCloudModel
        case .groqSTT:
            viewModel.groqSTTModel.isEmpty
                ? OpenAIAudioModelCatalog.groqWhisperModels[0] : viewModel.groqSTTModel
        case .soniox:
            viewModel.sonioxModel.isEmpty ? SonioxASRDefaults.model : viewModel.sonioxModel
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
             .qwen, .zhipu, .minimax, .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
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
        case .soniox:
            L("settings.models.routing.soniox")
        case .typefluxOfficial:
            L("settings.models.routing.typefluxOfficial")
        case .typefluxCloud:
            L("settings.models.routing.typefluxCloud")
        }
    }

    private var modelRoutingSecondaryTitle: String? {
        if viewModel.modelDomain == .stt {
            // Apple Speech fallback is intentionally hidden from all settings summaries.
            // return L("settings.models.routing.fallback")
            return nil
        }

        return activeModelProviderID == .ollama
            ? L("settings.models.routing.localSetup") : L("settings.models.routing.readiness")
    }

    private var modelRoutingSecondaryValue: String? {
        if viewModel.modelDomain == .stt {
            // Apple Speech fallback is intentionally hidden from all settings summaries.
            // return viewModel.appleSpeechFallback
            //     ? L("settings.models.routing.fallbackEnabled")
            //     : L("settings.models.routing.fallbackDisabled")
            return nil
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

    private func sheetCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StudioTheme.controlSurface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
