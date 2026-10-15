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

    var iconName: String {
        switch self {
        case .all:
            "line.3.horizontal.decrease.circle"
        case .automatic:
            "sparkles"
        case .manual:
            "hand.draw"
        case .otherApps:
            "square.stack.3d.up"
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
    private let vocabularySearchCollapsedSize: CGFloat = 44
    private let vocabularySearchExpandedWidth: CGFloat = 276
    private let vocabularySearchAnimation = Animation.interpolatingSpring(stiffness: 180, damping: 24)

    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var imageSettings: AskImageSettingsModel
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var isVocabularySearchExpanded = false
    @State private var isAddingVocabulary = false
    @State private var editingVocabularyEntry: VocabularyEntry?
    @State private var newVocabularyTerm = ""
    @FocusState private var isVocabularySearchFocused: Bool
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
    @State private var agentPane: AgentSettingsPane = .overview
    @StateObject private var interfaceStyleObserver: InterfaceStyleObserver
    @State private var launcherPane: LauncherSettingsPane
    @State private var settingsPane: AppSettingsPane

    /// `launcherPane` opens the Launcher page at one of its panes, e.g. the keyword list.
    init(viewModel: StudioViewModel, launcherPane: LauncherSettingsPane = .basics,
         settingsPane: AppSettingsPane = .general) {
        self.viewModel = viewModel
        _interfaceStyleObserver = StateObject(wrappedValue: InterfaceStyleObserver(settings: viewModel.askToolSettings))
        _imageSettings = StateObject(wrappedValue: AskImageSettingsModel(
            store: AskImageSettings(defaults: viewModel.askToolSettings.defaults)
        ))
        _launcherPane = State(initialValue: launcherPane)
        _settingsPane = State(initialValue: settingsPane)
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
            .background(vocabularyOutsideTapTarget)
            .id(viewModel.currentSection)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: viewModel.currentSection)
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
        .onReceive(viewModel.$directFeedbackRequestID.compactMap { $0 }.receive(on: RunLoop.main)) { _ in
            viewModel.directFeedbackRequestID = nil
            openDirectFeedback()
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
        VStack(spacing: StudioTheme.Spacing.none) {
            VoiceInputTabBar(
                selection: viewModel.currentSection,
                count: viewModel.voiceInputTabCount,
                onSelect: viewModel.navigate
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keep a clear gap below actions without moving the tab underline off the divider.
            .overlay(alignment: .bottom) {
                HStack(spacing: StudioTheme.Spacing.large) { pageHeaderActions }
                    .padding(.bottom, StudioTheme.Spacing.small)
            }
            Rectangle()
                .fill(StudioTheme.border)
                .frame(height: 1)
        }
    }

    /// The Models page header shares its tabs and action alignment with Voice Input.
    private var modelsHeader: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: StudioTheme.Spacing.large) {
                    modelTabs.fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: StudioTheme.Spacing.large) { pageHeaderActions }
                        .padding(.bottom, StudioTheme.Spacing.small)
                        .frame(height: 0, alignment: .bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(StudioTheme.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                VStack(spacing: 0) {
                    modelTabs.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(StudioTheme.border).frame(height: 1)
                }
                if viewModel.modelPageTab.domain != nil, !viewModel.isShowingModelProviderDetail {
                    HStack(spacing: StudioTheme.Spacing.large) { pageHeaderActions }
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

                HStack(spacing: StudioTheme.Spacing.medium) {
                    StudioButton(
                        title: L("vocabulary.action.newWord"), systemImage: "plus", variant: .secondary
                    ) {
                        editingVocabularyEntry = nil
                        newVocabularyTerm = ""
                        isAddingVocabulary = true
                    }

                    Menu {
                        Button(action: viewModel.importVocabulary) {
                            Label(L("vocabulary.action.importFile"), systemImage: "arrow.down.doc")
                        }
                        Button(action: viewModel.exportVocabulary) {
                            Label(L("vocabulary.action.export"), systemImage: "arrow.up.doc")
                        }
                        Divider()
                        Button(action: viewModel.importClaudeVocabulary) {
                            vocabularyMenuItemLabel(
                                title: L("vocabulary.action.importClaude"),
                                source: .claude
                            )
                        }
                        Button(action: viewModel.importCodexVocabulary) {
                            vocabularyMenuItemLabel(
                                title: L("vocabulary.action.importCodex"),
                                source: .codex
                            )
                        }
                    } label: {
                        vocabularyMoreMenuLabel
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: true, vertical: false)
                    .modifier(StudioButtonChromeModifier(
                        variant: .secondary,
                        isDisabled: viewModel.isSynchronizingVocabulary,
                        isLoading: false,
                        isPressed: false,
                        minWidth: StudioTheme.ControlSize.buttonMinWidth
                    ))
                    .disabled(viewModel.isSynchronizingVocabulary)
                }
            } else if viewModel.currentSection == .history {
                Spacer()

                HStack(spacing: StudioTheme.Spacing.medium) {
                    AskIconGhostButton(label: L("history.action.exportMarkdown"), systemImage: "square.and.arrow.up") {
                        viewModel.exportHistory()
                    }

                    AskIconGhostButton(label: L("common.clear"), systemImage: "trash") {
                        showingClearHistoryConfirmation = true
                    }
                }
            } else if viewModel.currentSection == .models {
                Spacer()

                // Provider lists can be searched; a provider's own settings have nothing to search.
                if let domain = viewModel.modelPageTab.domain, !viewModel.isShowingModelProviderDetail {
                    HStack(spacing: StudioTheme.Spacing.small) {
                        SettingsSearchBox(
                            placeholder: L("models.search"),
                            text: $viewModel.modelSearchQuery,
                            width: 220,
                            fieldIdentifier: "models.search"
                        )

                        if domain == .llm {
                            SettingsActionButton(
                                title: L("models.addEndpoint"),
                                symbol: "plus"
                            ) {
                                viewModel.isAddingModelEndpoint = true
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("models.addProvider")
                        }
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

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            StudioCard(padding: 16) {
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

                    Label(L("history.privacy.subtitle"), systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                    if record.id != section.records.last?.id {
                                        Divider().overlay(
                                            StudioTheme.border.opacity(
                                                StudioTheme.Opacity.listDivider
                                            )
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

                vocabularySearchControl
            }

            StudioCard(showsChrome: colorScheme == .dark) {
                Group {
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
                            vocabularyEmptyActions
                        }
                        .padding(.vertical, StudioTheme.Insets.historyEmptyVertical)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 240), spacing: StudioTheme.Spacing.xLarge)],
                            alignment: .leading,
                            spacing: StudioTheme.Spacing.mediumLarge
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
        case .advanced:
            advancedSettingsPage
        }
    }

    private var generalSettingsPage: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection {
                settingSwitch(L("settings.launchAtLogin.title"), detail: L("settings.launchAtLogin.subtitle"),
                              isOn: Binding(get: { viewModel.launchAtLogin }, set: viewModel.setLaunchAtLogin))
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

            TFFormSection(title: L("settings.inputAndCapture.title")) {
                TFFormRow(title: L("settings.shortcuts.quickInput.title"),
                          detail: L("settings.shortcuts.quickInput.subtitle"), badge: "Beta") {
                    TFSwitch(title: L("settings.shortcuts.quickInput.title"),
                             isOn: Binding(get: { viewModel.quickInputEnabled }, set: viewModel.setQuickInputEnabled))
                        .accessibilityIdentifier("settings.quickInput")
                }
                TFDivider.form
                launcherPositionSetting
                TFDivider.form
                screenshotSaveLocationSetting
            }

            TFFormSection(title: L("settings.audio")) {
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
                settingSwitch(L("settings.instantVoiceInput.title"), detail: L("settings.instantVoiceInput.subtitle"),
                              badge: "Beta",
                              isOn: Binding(get: { viewModel.instantVoiceInputEnabled },
                                            set: viewModel.setInstantVoiceInputEnabled))
                TFDivider.form
                settingSwitch(L("settings.mouseVoice.title"), detail: L("settings.mouseVoice.subtitle"), badge: "Beta",
                              isOn: Binding(get: { viewModel.mouseVoiceInputEnabled },
                                            set: viewModel.setMouseVoiceInputEnabled))
                if viewModel.mouseVoiceInputEnabled {
                    TFDivider.form
                    TFFormRow(title: L("settings.mouseVoice.activation.title"),
                              detail: L("settings.mouseVoice.activation.subtitle")) {
                        TFPopUpButton(
                            title: L("settings.mouseVoice.activation.title"),
                            options: MouseVoiceActivationStyle.allCases.map { TFOption($0, $0.displayName) },
                            selection: Binding(get: { viewModel.mouseVoiceActivationStyle },
                                               set: viewModel.setMouseVoiceActivationStyle),
                            width: TFMetrics.formControlWidth
                        )
                    }
                }
                TFDivider.form
                settingSwitch(L("settings.mute.title"), detail: L("settings.mute.subtitle"),
                              isOn: Binding(get: { viewModel.muteSystemOutputDuringRecording },
                                            set: viewModel.setMuteSystemOutputDuringRecording))
            }

            TFFormSection(title: L("settings.permissions")) {
                TFFormRow(title: L("settings.permissionStatus.title"), detail: L("settings.permissionStatus.subtitle")) {
                    TFButton(
                        title: viewModel.isRefreshingPermissions ? L("common.refreshing") : L("common.refresh"),
                        systemImage: "arrow.clockwise",
                        isLoading: viewModel.isRefreshingPermissions
                    ) {
                        viewModel.refreshPermissionRowsWithFeedback()
                    }
                }
                ForEach(viewModel.permissionRows) { permission in
                    TFDivider.form
                    permissionRow(permission)
                }
            }

            TFFormSection(title: L("settings.other")) {
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
                TFDivider.form
                settingSwitch(L("settings.advanced.autoUpdate.title"), detail: L("settings.advanced.autoUpdate.subtitle"),
                              isOn: Binding(get: { viewModel.autoUpdateEnabled }, set: viewModel.setAutoUpdateEnabled))
                TFDivider.form
                settingSwitch(L("settings.analyticsSharing.title"), detail: L("settings.analyticsSharing.subtitle"),
                              isOn: Binding(get: { viewModel.analyticsSharingEnabled },
                                            set: viewModel.setAnalyticsSharingEnabled))
            }
        }
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
                      detail: viewModel.cloudServerTestSummary ?? L("settings.servers.speedTest.subtitle")) {
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
        SettingsPaneLayout(sections: AgentSettingsPane.sections, selection: $agentPane, compact: compact,
                           status: agentPaneStatus) {
            if agentPane == .mcpServers {
                AgentPaneHeader(symbol: AgentCapability.mcpServers.symbol, title: AgentCapability.mcpServers.title) {
                    if !viewModel.mcpServers.isEmpty {
                        Button { beginMCPImport() } label: {
                            Label(L("agent.mcp.import.action"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(ModelActionStyle())
                        Button {
                            viewModel.beginAddMCPServer()
                            isMCPServerDialogPresented = true
                        } label: {
                            Label(L("agent.mcp.addServer"), systemImage: "plus")
                        }
                        .buttonStyle(ModelActionStyle(primary: true))
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
                clipboardHistory: SettingsWindowController.shared.clipboardHistoryStore,
                onEditShortcut: {
                    settingsPane = .hotkeys
                    viewModel.navigate(to: .settings)
                }
            )
            .id(launcherPane)
        }
    }

    @ViewBuilder private var agentMCPServersTabContent: some View {
        if viewModel.mcpServers.isEmpty {
            ModelSurface {
                AgentEmptyState(symbol: "server.rack", title: L("agent.mcp.emptyTitle"), message: L("agent.mcp.emptyMessage")) {
                    Button {
                        viewModel.beginAddMCPServer()
                        isMCPServerDialogPresented = true
                    } label: {
                        Label(L("agent.mcp.addServer"), systemImage: "plus")
                    }
                    .buttonStyle(ModelActionStyle(primary: true))
                    Button { beginMCPImport() } label: {
                        Label(L("agent.mcp.import.action"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ModelActionStyle())
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ModelSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.mcpServers.enumerated()), id: \.element.id) { index, server in
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
        .background(ModelVisualStyle.canvas)
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
                  detail: viewModel.screenshotSaveDirectory.path) {
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

    /// Where ⌥Space opens the launcher: always centred, or where it was last dragged.
    private var launcherPositionSetting: some View {
        TFFormRow(
            title: L("settings.shortcuts.launcherPosition.title"),
            detail: L(viewModel.askLauncherPosition == .center
                ? "settings.shortcuts.launcherPosition.center.subtitle"
                : "settings.shortcuts.launcherPosition.last.subtitle")
        ) {
            if viewModel.askLauncherPosition == .lastPosition {
                TFButton(title: L("settings.shortcuts.launcherPosition.reset"), kind: .link) {
                    viewModel.resetAskLauncherPositions()
                }
                .disabled(!viewModel.hasRememberedLauncherPositions)
            }
            TFSegmentedControl(
                options: [TFOption(AskLauncherPosition.center, L("settings.shortcuts.launcherPosition.center")),
                          TFOption(.lastPosition, L("settings.shortcuts.launcherPosition.last"))],
                selection: Binding(get: { viewModel.askLauncherPosition }, set: viewModel.setAskLauncherPosition)
            )
        }
        .onAppear { viewModel.refreshAskLauncherPositions() }
    }

    private func permissionRow(_ permission: StudioPermissionRowModel) -> some View {
        let tint = permission.isGranted ? TFColors.success : TFColors.warning
        return TFFormRow(
            title: permission.title,
            detail: permission.summary,
            footnote: permission.detail,
            badge: permission.badgeText,
            badgeTint: tint,
            systemImage: permission.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle",
            imageTint: tint
        ) {
            TFButton(
                title: permission.actionTitle,
                systemImage: permission.isGranted ? "arrow.up.right.square" : "lock.open.display",
                kind: permission.isGranted ? .secondary : .primary
            ) {
                viewModel.requestPermission(permission.id)
            }
        }
    }

    private var filteredVocabularyEntries: [VocabularyEntry] {
        viewModel.filteredVocabularyEntries.filter { vocabularyFilter.matches($0.source) }
    }

    @ViewBuilder
    private var vocabularyOutsideTapTarget: some View {
        if viewModel.currentSection == .vocabulary, isVocabularySearchExpanded {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    collapseVocabularySearch()
                }
        }
    }

    private var vocabularySearchControl: some View {
        HStack(spacing: isVocabularySearchExpanded ? StudioTheme.Spacing.small : StudioTheme.Spacing.none) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                .foregroundStyle(
                    isVocabularySearchExpanded ? StudioTheme.textTertiary : StudioTheme.textSecondary
                )
                .frame(width: vocabularySearchCollapsedSize, height: vocabularySearchCollapsedSize)

            if isVocabularySearchExpanded {
                TextField(L("vocabulary.search.placeholder"), text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .focused($isVocabularySearchFocused)
                    .onSubmit {
                        collapseVocabularySearch()
                    }
                    .onChange(of: isVocabularySearchFocused) { isFocused in
                        if !isFocused {
                            collapseVocabularySearch()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.trailing, isVocabularySearchExpanded ? StudioTheme.Insets.textFieldHorizontal : 0)
        .frame(
            width: isVocabularySearchExpanded ? vocabularySearchExpandedWidth : vocabularySearchCollapsedSize,
            height: vocabularySearchCollapsedSize,
            alignment: .leading
        )
        .background(
            Capsule()
                .fill(StudioTheme.controlSurface.opacity(StudioTheme.Opacity.textFieldFill))
        )
        .overlay(
            Capsule()
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin
                )
        )
        .contentShape(Capsule())
        .clipped()
        .onTapGesture {
            if !isVocabularySearchExpanded {
                expandVocabularySearch()
            }
        }
        .animation(vocabularySearchAnimation, value: isVocabularySearchExpanded)
    }

    @ViewBuilder
    private var vocabularyEmptyActions: some View {
        if vocabularyFilter == .otherApps, vocabularyCount(for: .otherApps) == 0 {
            HStack(spacing: StudioTheme.Spacing.small) {
                StudioButton(
                    title: L("vocabulary.action.importClaude"),
                    systemImage: "arrow.down.doc",
                    variant: .secondary,
                    isDisabled: viewModel.isSynchronizingVocabulary
                ) {
                    viewModel.importClaudeVocabulary()
                }
                StudioButton(
                    title: L("vocabulary.action.importCodex"),
                    systemImage: "arrow.down.doc",
                    variant: .secondary,
                    isDisabled: viewModel.isSynchronizingVocabulary
                ) {
                    viewModel.importCodexVocabulary()
                }
            }
        } else {
            StudioButton(
                title: L("vocabulary.action.addFirst"), systemImage: "plus",
                variant: .secondary
            ) {
                editingVocabularyEntry = nil
                newVocabularyTerm = ""
                isAddingVocabulary = true
            }
        }
    }

    private func vocabularyFilterChip(_ filter: VocabularyFilter) -> some View {
        Button {
            vocabularyFilter = filter
        } label: {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: filter.iconName)
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .fixedSize()
                Text(filter.title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(vocabularyCount(for: filter))")
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .bold))
                    .foregroundStyle(
                        vocabularyFilter == filter
                            ? StudioTheme.textPrimary : StudioTheme.textTertiary
                    )
                    .fixedSize()
            }
            .foregroundStyle(
                vocabularyFilter == filter ? StudioTheme.textPrimary : StudioTheme.textSecondary
            )
            .lineLimit(1)
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .padding(.vertical, StudioTheme.Insets.pillVertical + 3)
            .background(
                Capsule()
                    .fill(
                        vocabularyFilter == filter
                            ? StudioTheme.filterChipSelectedFill : StudioTheme.surfaceMuted.opacity(0.82)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                        lineWidth: StudioTheme.BorderWidth.thin
                    )
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
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                StudioTheme.modalSurface
            }
        )
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

    private func expandVocabularySearch() {
        withAnimation(vocabularySearchAnimation) {
            isVocabularySearchExpanded = true
        }

        DispatchQueue.main.async {
            isVocabularySearchFocused = true
        }
    }

    private func collapseVocabularySearch() {
        isVocabularySearchFocused = false

        withAnimation(vocabularySearchAnimation) {
            isVocabularySearchExpanded = false
        }
    }

    private var vocabularyMoreMenuLabel: some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            Image(systemName: "chevron.down")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
            Text(L("vocabulary.action.more"))
                .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
        .padding(.vertical, StudioTheme.Insets.buttonVertical)
    }

    private func vocabularyMenuItemIcon(for source: VocabularySource) -> some View {
        Group {
            if let image = vocabularySourceMenuIconImage(for: source) {
                Image(nsImage: image)
                    .interpolation(.high)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
            }
        }
        .frame(width: 16, height: 16)
    }

    private func vocabularyMenuItemLabel(title: String, source: VocabularySource) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            vocabularyMenuItemIcon(for: source)
            Text(title)
        }
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

    private func historyTable(records: [HistoryPresentationRecord]) -> some View {
        StudioCard(padding: StudioTheme.Insets.none) {
            VStack(spacing: StudioTheme.Spacing.none) {
                HStack {
                    Text(L("history.table.timestamp"))
                        .frame(
                            width: StudioTheme.Layout.historyTimestampColumnWidth,
                            alignment: .leading
                        )
                    Text(L("history.table.sourceFile"))
                        .frame(
                            width: StudioTheme.Layout.historySourceColumnWidth, alignment: .leading
                        )
                    Text(L("history.table.recognizedText"))
                    Spacer()
                }
                .font(.studioBody(StudioTheme.Typography.sidebarEyebrow, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, StudioTheme.Insets.historyHeaderHorizontal)
                .padding(.top, StudioTheme.Insets.historyHeaderTop)
                .padding(.bottom, StudioTheme.Insets.historyHeaderBottom)

                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

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
                            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                        }
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            ModelDetailHeader(
                title: focusedProviderTitle,
                icon: viewModel.focusedModelProvider,
                connected: focusedProviderConnected,
                backTitle: ModelPageTab.speech.title,
                onBack: { viewModel.isShowingSpeechProviderDetail = false }
            )
            .padding(.bottom, 22)
            SettingsListSectionLabel(title: L("models.connection")).padding(.bottom, 8)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    focusedProviderForm
                    focusedProviderActions
                    if viewModel.focusedModelProvider == .localSTT {
                        localSTTStorageRow
                    }
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
                        .font(.studioMono(12)).textSelection(.enabled)
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
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
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
                }
                ModelRowDivider()

            case .localSTT:
                VStack(spacing: 0) {
                    ForEach(LocalSTTModel.displayOrder, id: \.self) { model in
                        localSTTModelOptionCard(model)
                        ModelRowDivider()
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
                    Text(L("settings.models.multimodalLLM.audioHint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
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
                    ModelRowDivider()
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
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            if !authState.isLoggedIn {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    Text(message)
                        .font(.studioBody(StudioTheme.Typography.caption))
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
                                cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous
                            )
                            .fill(StudioTheme.controlSurface)
                        )
                }
            }
        case let .notice(message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(message)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isActive {
                        StudioPill(title: L("settings.models.selected"), tone: StudioTheme.accent,
                                   fill: StudioTheme.accentSoft)
                    }
                }
                HStack {
                    Text("\(specs.parameterValue) parameters · \(specs.sizeValue)")
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    Spacer()
                    localSTTModelDownloadIconButton(model)
                }
                if isFocused, viewModel.isPreparingLocalSTT || !isDownloaded {
                    localSTTModelProgressRow(model)
                    Text(viewModel.localSTTPreparationDetail)
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    if !viewModel.localSTTTransferDetail.isEmpty {
                        Text(viewModel.localSTTTransferDetail)
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
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
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                .foregroundStyle(viewModel.isPreparingLocalSTT ? StudioTheme.textTertiary : StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
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

private struct VocabularyTermCard: View {
    let entry: VocabularyEntry
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    /// Light: a white card with a 1px hairline; dark keeps the translucent surface.
    private var cardFill: Color { colorScheme == .dark ? StudioTheme.surface : StudioTheme.cardFill }
    private var cardStroke: Color {
        colorScheme == .dark
            ? StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder) : StudioTheme.cardStroke
    }

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            vocabularySourceBadge

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
                            .fill(StudioTheme.controlSurface)
                    )
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .padding(.horizontal, StudioTheme.Insets.cardCompact)
        .padding(.vertical, StudioTheme.Insets.buttonVertical + 2)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                .stroke(cardStroke, lineWidth: StudioTheme.BorderWidth.thin)
        )
        .contentShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L("common.copy"), systemImage: "doc.on.doc", action: onCopy)
            Button(L("common.edit"), systemImage: "pencil", action: onEdit)
            Button(L("common.delete"), systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var vocabularySourceBadge: some View {
        if let image = vocabularySourceLogoImage(for: entry.source) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            // Light: a neutral sparkle; dark keeps the original accent asterisk.
            Image(systemName: colorScheme == .dark ? "asterisk" : "sparkles")
                .font(.system(size: StudioTheme.Typography.iconRegular, weight: colorScheme == .dark ? .bold : .regular))
                .foregroundStyle(colorScheme == .dark ? StudioTheme.warning : StudioTheme.textTertiary)
        }
    }
}
