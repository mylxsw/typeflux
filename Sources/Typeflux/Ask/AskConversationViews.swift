// swiftlint:disable file_length type_body_length
import AppKit
import Combine
import SwiftUI

struct AskConversationView: View {
    @ObservedObject var model: AskConversationModel
    @State private var showsUsage = false
    /// The embedded browser panel; it stays open across conversations.
    @State private var showsBrowser = false
    @AppStorage("ask.browser.panelWidth") private var browserWidth: Double = 560
    @State private var browserDragBase: CGFloat?
    @State private var usageRunId: String?
    @State private var deleteId: String?
    @State private var newMenuOpen = false
    @State private var pullDistance: CGFloat = 0
    @State private var restoredTranscript: String?
    @State private var isSearching = false
    @State private var collapsedGroups: Set<String> = []
    /// The run whose step-limit prompt the user ended, so it stays dismissed.
    @State private var endedStepLimitRunId: String?
    /// Which conversations the sidebar lists while some are kept on this Mac.
    @State private var historyFilter = AskHistoryFilter.all
    @State private var historyKind: AskConversationKind?
    @State private var searchHover = false
    /// The selected row's pill slides between rows instead of jumping.
    @Namespace private var selectionSpace
    /// Height of the banners and composer floating over the transcript's bottom edge.
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var transcriptViewportSize: CGSize = .zero
    @State private var transcriptCoveredBottom: CGFloat = 0
    /// Files are dragged over the transcript; they attach to the draft when dropped.
    @State private var transcriptDropTargeted = false
    /// Set by the toggle inside its animation. Driving the layout from the
    /// `@AppStorage` value alone re-rendered outside the animation, so the
    /// sidebar popped in and out instead of sliding.
    @State private var sidebarChoice: Bool?
    @AppStorage("ask.sidebarCollapsed") private var storedSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceStyle) private var style
    @State private var windowSize = AskWorkspaceLayout.minimumWindowSize
    @State private var showsSidebarDrawer = false
    @FocusState private var drawerCloseFocused: Bool
    @State private var previousResponder: NSResponder?
    @ObservedObject private var auth: AuthState

    @MainActor
    init(model: AskConversationModel, showsUsage: Bool = false, auth: AuthState? = nil) {
        self.model = model
        self.auth = auth ?? .shared
        _showsUsage = State(initialValue: showsUsage)
        _usageRunId = State(initialValue: model.selected?.run?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            workspace
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { windowSize = geometry.size }
                .onChange(of: geometry.size) { windowSize = $0 }
        }
        .overlay {
            if model.inspectingRecovery && model.hasRecoveryNotice {
                ZStack {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                    AskRecoveryInspector(model: model)
                        .frame(maxWidth: 480)
                        .background(AskTheme.popoverSurface,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                        .padding(20)
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        // Measure the viewport, rather than the intrinsic width of its children.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.selectedId) { _ in
            usageRunId = nil
            showsUsage = false
            showsSidebarDrawer = false
        }
        .onChange(of: model.authoringSession?.revision) { _ in
            if model.authoringSession?.isPresented == true { showsUsage = false; showsBrowser = false }
        }
        .onReceive(browserPresentation) { _ in setBrowser(true) }
        .onChange(of: model.runPhase?.offersStop == true) { active in
            // A finished run no longer controls the browser, and its pause never carries over.
            if !active, let id = model.selectedId { model.tools.browserWorkspace?.endActivity(conversationId: id) }
        }
        .onChange(of: layout.sidebarInline) { inline in
            if inline { showsSidebarDrawer = false }
        }
        .onChange(of: layout.usageOverlay) { overlay in
            // A resize must not queue a second drawer behind the open history.
            if overlay, showsSidebarDrawer { showsUsage = false }
        }
        .onChange(of: hasModal) { shown in
            if shown {
                if let window = NSApp.keyWindow,
                   window.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-conversations" {
                    previousResponder = window.firstResponder
                    window.makeFirstResponder(nil)
                }
                if hasDrawer { drawerCloseFocused = true }
            } else {
                if let editor = previousResponder as? NSView {
                    // Let the background controls become enabled before restoring
                    // focus, and never redirect a different window's responder.
                    DispatchQueue.main.async { [weak editor] in
                        guard let editor, let window = editor.window, window.isKeyWindow else { return }
                        window.makeFirstResponder(editor)
                    }
                }
                previousResponder = nil
            }
        }
        .onDisappear { model.setRemoteImagesVisible(false) }
        .onChange(of: auth.isLoggedIn) { _ in accountDidChange() }
        .onChange(of: auth.userProfile?.id) { _ in accountDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .authTokenDidRefresh)) { notification in
            if let changed = notification.object as? AuthState, changed === auth { accountDidChange() }
        }
        .tint(AskTheme.accent)
        .environment(\.askContextImageAccess, model.contextImageAccess(launcher: false))
        .environment(\.askRemoteImageAccess, model.remoteImageAccess)
        .environment(\.askArtifactAccess, model.artifactAccess)
        .environment(\.askTerminalAccess, model.terminalAccess)
        .onChange(of: model.draft) { _ in model.persistDrafts() }
        .confirmationDialog(
            L("ask.delete.confirm"),
            isPresented: Binding(get: { deleteId != nil }, set: { if !$0 { deleteId = nil } })
        ) {
            Button(L("ask.delete"), role: .destructive) {
                if let id = deleteId { Task { await model.delete(id) } }
                deleteId = nil
            }
            Button(L("common.cancel"), role: .cancel) { deleteId = nil }
        }
    }

    private var layout: AskWorkspaceLayout {
        AskWorkspaceLayout(size: windowSize, sidebarCollapsed: sidebarCollapsed,
                           showsUsage: showsUsage || showsWorkflow || showsBrowserPanel,
                           rightPanelWidth: showsBrowserPanel ? CGFloat(browserWidth) : (showsWorkflow ? 390 : nil))
    }

    private func accountDidChange() {
        model.invalidateRemoteImages()
        Task { await model.refreshAfterAccountChange() }
    }

    private var showsWorkflow: Bool { model.authoringSession?.isPresented == true && !showsUsage && !showsBrowser }
    private var showsBrowserPanel: Bool { showsBrowser && !showsUsage && model.tools.browserWorkspace != nil }

    private var browserPresentation: AnyPublisher<Int, Never> {
        model.tools.browserWorkspace?.$presentationRequest.dropFirst().eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    private func setBrowser(_ shown: Bool) {
        guard shown != showsBrowser || (shown && showsUsage) else { return }
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            showsSidebarDrawer = false
            isSearching = false
            if shown {
                showsUsage = false
                model.authoringSession?.isPresented = false
                if model.tools.browserWorkspace?.tabs.isEmpty == true {
                    _ = try? model.tools.browserWorkspace?.newTab()
                }
            }
            showsBrowser = shown
        }
    }

    /// The conversation keeps at least 420pt beside the panel.
    private func resizeBrowser(_ delta: CGFloat?) {
        guard let delta else { browserDragBase = nil; return }
        let base = browserDragBase ?? CGFloat(browserWidth)
        browserDragBase = base
        let maximum = max(380, windowSize.width - (layout.sidebarInline ? AskMetrics.sidebarWidth : 0) - 420)
        browserWidth = Double(min(maximum, max(380, base + delta)))
    }

    @ViewBuilder private var rightPanel: some View {
        if showsBrowserPanel, let workspace = model.tools.browserWorkspace {
            AskBrowserPanel(workspace: workspace, floating: layout.usageOverlay,
                            runningConversationId: model.runPhase?.offersStop == true ? model.selectedId : nil,
                            stopRun: { model.stop() }, close: { setBrowser(false) },
                            resize: layout.usageOverlay ? nil : resizeBrowser)
                .frame(width: layout.usageInline ? layout.usageWidth : layout.drawerWidth)
        } else if showsWorkflow, let session = model.authoringSession {
            AskWorkflowAuthoringPanel(session: session, focusCloseOnAppear: layout.usageOverlay,
                                      floating: layout.usageOverlay, close: {
                session.isPresented = false
                model.objectWillChange.send()
            }, discard: {
                guard let id = model.selectedId else { return }
                do { try model.workflowAuthoring?.remove(id) }
                catch { session.message = error.localizedDescription }
            }, complete: { model.sendFollowUp($0) },
               completing: model.runPhase?.isWorking == true, canComplete: !model.isBusy)
            .frame(width: layout.usageInline ? layout.usageWidth : layout.drawerWidth)
        } else {
            AskUsagePanel(model: model, compact: layout.isShort, focusCloseOnAppear: layout.usageOverlay,
                          floating: layout.usageOverlay, runId: $usageRunId, close: { setUsage(false) })
        }
    }

    private var hasDrawer: Bool { showsSidebarDrawer || layout.usageOverlay }
    private var hasModal: Bool { hasDrawer || isSearching || model.inspectingRecovery }

    private var workspace: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if !sidebarHidden {
                        sidebar.frame(width: AskMetrics.sidebarWidth)
                            .transition(AskMotion.panel(edge: .leading, reduceMotion: reduceMotion))
                    }
                    content
                    if layout.usageInline {
                        rightPanel
                            .id(model.selectedId)
                            .transition(AskMotion.panel(edge: .trailing, reduceMotion: reduceMotion))
                    }
                }
                // One canvas for the whole window; the sidebar column lays its
                // clearer glass over it, flush with the window edge.
                .background(AskWindowBackdrop())
                titleBarTools
            }
            .disabled(hasModal)
            .accessibilityHidden(hasModal)
            if hasDrawer { drawer }
            if isSearching { searchPalette }
        }
        .clipped()
    }

    // MARK: - Sidebar

    /// The user's choice: this window's latest toggle, else the stored preference.
    private var sidebarCollapsed: Bool { sidebarChoice ?? storedSidebarCollapsed }

    /// Hidden by the user, or stepping aside while the usage panel needs the
    /// room: three columns overflowed a narrow window and pushed the sidebar
    /// against its edge.
    private var sidebarHidden: Bool { !layout.sidebarInline }

    private var drawer: some View {
        ZStack(alignment: showsSidebarDrawer ? .leading : .trailing) {
            Color.black.opacity(0.24)
                .contentShape(Rectangle())
                .onTapGesture { closeDrawer() }
                .accessibilityHidden(true)
            if showsSidebarDrawer {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("ask.search.conversations")).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(action: closeDrawer) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel(L("ask.artifact.close"))
                            .accessibilityIdentifier("ask.workspace.drawer.close")
                            .focused($drawerCloseFocused)
                    }
                    // Beside the traffic lights, in the title bar row.
                    .padding(.leading, AskMetrics.trafficLightInset)
                    .padding(.trailing, 12)
                    .frame(height: AskMetrics.titleBarRowHeight)
                    sidebarSearchField.padding(.horizontal, AskMetrics.sidebarContentInset).padding(.bottom, 8)
                    historyFilterPicker.padding(.horizontal, AskMetrics.sidebarContentInset).padding(.bottom, 8)
                    historyList
                    accountFooter
                }
                .frame(width: min(AskMetrics.sidebarWidth, layout.drawerWidth))
                .askSidePanel(edge: .leading, floating: true)
                .transition(AskMotion.panel(edge: .leading, reduceMotion: reduceMotion))
            } else {
                rightPanel
                    .frame(width: layout.drawerWidth)
                    .padding(.top, layout.usageOverlayTopInset)
                    .transition(AskMotion.panel(edge: .trailing, reduceMotion: reduceMotion))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onExitCommand(perform: closeDrawer)
    }

    private func closeDrawer() {
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            if !showsSidebarDrawer {
                showsUsage = false
                showsBrowser = false
                model.authoringSession?.isPresented = false
            }
            showsSidebarDrawer = false
        }
    }

    /// A full-height column flush with the window edge, with the traffic lights
    /// in its top strip: clearer glass than the canvas in Liquid Glass, solid
    /// in classic.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window uses a full-size content view; this strip clears the
            // traffic lights. The compose and toggle buttons float above it.
            Color.clear.frame(height: AskMetrics.sidebarTopInset)
            sidebarSearchField.padding(.horizontal, AskMetrics.sidebarContentInset)
                .padding(.top, 4).padding(.bottom, 8)
            historyFilterPicker.padding(.horizontal, AskMetrics.sidebarContentInset).padding(.bottom, 8)
            historyList
            accountFooter
        }
        .askSidePanel(edge: .leading)
    }

    /// New chat and the sidebar toggle live in the title bar row, like Notes and
    /// Mail. Expanded, they are right-aligned inside the sidebar; collapsed, they
    /// follow the traffic lights with search, so "new chat" never moves out of
    /// reach. Either way they share one glass pill like the header's.
    private var titleBarTools: some View {
        HStack(spacing: 2) {
            if !sidebarHidden { Spacer(minLength: 0) }
            if sidebarHidden {
                collapsedTools.askCollapsedSidebarTools()
            } else {
                expandedTools
                    .padding(.horizontal, style.usesGlass ? 3 : 0)
                    .frame(height: AskMetrics.headerCapsuleHeight)
                    .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            }
        }
        .padding(.leading, sidebarHidden ? AskMetrics.trafficLightInset : 0)
        // The glass pill's trailing edge lines up with the search field below it.
        .padding(.trailing, sidebarHidden ? 0 : AskMetrics.sidebarToolsTrailing(glass: style.usesGlass))
        .frame(width: sidebarHidden ? nil : AskMetrics.sidebarWidth, alignment: .leading)
        .frame(height: AskMetrics.titleBarRowHeight)
        .background {
            if layout.compactContent {
                // A native Menu creates its items lazily. Register search even
                // before the compact overflow menu has been opened once.
                Button(L("ask.search"), action: openSearch)
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var sidebarToggle: some View {
        titleBarButton("sidebar.left", label: L("ask.sidebar.toggle"), shortcut: "⌃⌘S") { toggleSidebar() }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityIdentifier("ask.workspace.sidebar")
    }

    private func toggleSidebar() {
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            if !layout.sidebarInline,
               windowSize.width - (layout.usageInline ? layout.usageWidth : 0)
               < AskMetrics.sidebarWidth + AskWorkspaceLayout.comfortableContentWidth {
                // Opening the drawer never overwrites a preference for a wider window.
                if layout.usageOverlay { showsUsage = false }
                showsSidebarDrawer.toggle()
            } else {
                sidebarChoice = !sidebarCollapsed
                storedSidebarCollapsed = sidebarChoice ?? false
            }
        }
    }

    private var expandedTools: some View {
        HStack(spacing: 2) {
            savedDraftMenu
            composeButton
            sidebarToggle
        }
    }

    /// Expanded, the sidebar owns the search entry; collapsed, it moves here.
    private var collapsedTools: some View {
        HStack(spacing: 0) {
            sidebarToggle
            if !layout.compactContent {
                titleBarButton("magnifyingglass", label: L("ask.search")) { openSearch() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            savedDraftMenu
            composeButton
        }
    }

    @ViewBuilder
    private var savedDraftMenu: some View {
        if !model.savedChatDrafts.isEmpty {
            Menu {
                ForEach(model.savedChatDrafts) { saved in
                    Button(saved.draft.title.isEmpty ? L("ask.drafts.untitled") : String(saved.draft.title.prefix(60))) {
                        Task { await model.restoreChatDraft(saved) }
                    }
                }
            } label: {
                Image(systemName: "tray.full")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("ask.drafts.saved"))
            .accessibilityLabel(L("ask.drafts.saved"))
            .disabled(model.isOpeningChat)
        }
    }

    /// The window's one "new chat" entry: a menu of the kinds of conversation.
    /// The shortcuts still start each kind directly.
    private var composeButton: some View {
        titleBarButton("square.and.pencil", label: L("ask.new"), shortcut: nil) { newMenuOpen.toggle() }
            .accessibilityIdentifier("ask.workspace.new")
            .askMenu(isPresented: $newMenuOpen, glass: true) {
                AskNewConversationMenu(model: model) { newMenuOpen = false }
            }
            .background { newConversationShortcuts }
    }

    /// ⌘N, ⇧⌘N and ⌥⌘N without more visible controls in the title bar.
    private var newConversationShortcuts: some View {
        ZStack {
            Button(L("ask.new")) { model.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("ask.storage.newLocal")) { model.newConversation(storesLocally: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isSignedIn)
            Button(L("ask.temporary.new")) { model.newConversation(temporary: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func titleBarButton(_ symbol: String, label: String, shortcut: String? = nil,
                                action: @escaping () -> Void) -> some View {
        AskTitleBarButton(symbol: symbol, label: label, shortcut: shortcut, action: action)
    }

    /// One search entry point for the whole window: the field and ⌘K open the
    /// same palette, instead of a magnifier icon plus a list that repeats the
    /// sidebar.
    private var sidebarSearchField: some View {
        Button { openSearch() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                Text(L("ask.search")).font(.system(size: 13))
                Spacer(minLength: 4)
                AskKeyHint(text: "⌘K")
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, style.usesGlass ? 10 : 8)
            .frame(height: style.ask.searchFieldHeight)
            .background(searchHover ? AskTheme.pressFill : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous))
            .overlay {
                // A classic field is a plain well; the hairline belongs to the glass.
                if style.usesGlass {
                    RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous)
                        .strokeBorder(AskTheme.separator, lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { searchHover = $0 }
        .keyboardShortcut("k", modifiers: .command)
        .help(L("ask.search"))
        .accessibilityLabel(L("ask.search"))
    }

    private func openSearch() {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) {
            closeDrawer()
            isSearching = true
        }
    }

    private func closeSearch() {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) { isSearching = false }
    }

    private var accountFooter: some View {
        SidebarAccountFooter(auth: auth, compact: layout.isShort,
                             defaults: model.modelLibrary.settings.defaults,
                             onSignIn: { LoginWindowController.shared.show() },
                             onOpenAccount: { model.onOpenSettings?(.account) },
                             onOpenSettings: { model.onOpenSettings?(.settings) }) {
            AskLocalModeIdentity(model: model)
        }
    }

    // MARK: - Search palette

    private var searchPalette: some View {
        AskSearchPaletteView(
            conversations: model.conversations,
            available: paletteActions,
            onAction: { action in
                closeSearch()
                runPaletteAction(action)
            },
            onOpen: { id in
                closeSearch()
                Task { await model.select(id) }
            },
            onClose: closeSearch
        )
    }

    /// Actions that can do something in the window's current state.
    private var paletteActions: [AskPaletteAction] {
        AskPaletteAction.allCases.filter { action in
            switch action {
            case .attachScreenshot:
                return model.screenshotCapability(launcher: false).canAttach && !model.draft.includeScreenshot
            case .usage:
                return model.selectedId != nil
            case .newPrivateConversation:
                return model.isSignedIn
            default:
                return true
            }
        }
    }

    private func runPaletteAction(_ action: AskPaletteAction) {
        switch action {
        case .newConversation: model.newConversation()
        case .newPrivateConversation: model.newConversation(storesLocally: true)
        case .toggleSidebar: toggleSidebar()
        case .usage: if !showsUsage { toggleUsage() }
        case .attachScreenshot:
            model.draft.includeScreenshot = true
            if model.draft.screenshot == nil { Task { await model.refreshScreenshot(launcher: false) } }
        }
    }

    /// Local rows need a storage mark only while signed in, alongside Cloud history.
    private var marksLocalHistory: Bool { model.isSignedIn && !model.localConversationIds.isEmpty }

    private var visibleConversations: [AskConversationSummary] {
        let stored = historyFilter.apply(model.conversations, isLocal: model.isLocal)
        return stored.filtered(kind: historyKind)
    }

    /// Keep the storage filter available regardless of account or history contents.
    private var historyFilterPicker: some View {
        HStack(spacing: 6) {
            AskHistoryKindBar(selection: $historyKind)
            AskHistoryStorageMenu(selection: $historyFilter)
        }
    }

    private var historyList: some View {
        let now = Date()
        let calendar = Calendar.current
        let items = AskHistoryPeriod.ordered(visibleConversations, now: now, calendar: calendar)
        return ScrollView {
            LazyVStack(spacing: 2) {
                if model.historyHasPendingSync {
                    Label(L("ask.history.syncPending"), systemImage: "icloud.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                if model.isTemporaryComposer(launcher: false) {
                    AskTemporaryHistoryRow().padding(.top, 4)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let period = AskHistoryPeriod.period(for: item.updatedAt, now: now, calendar: calendar)
                    let title = L(period.titleKey)
                    if index == 0 || AskHistoryPeriod.period(for: items[index - 1].updatedAt, now: now,
                                                             calendar: calendar) != period {
                        groupHeader(title, first: index == 0)
                    }
                    if !collapsedGroups.contains(title) {
                        historyRow(item)
                    }
                }
                if model.historyHasMore {
                    Button(L("ask.loadMore")) { Task { await model.refreshHistory(loadMore: true) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AskTheme.accentText)
                        .padding(.top, 8)
                }
                if items.isEmpty, !model.isTemporaryComposer(launcher: false) {
                    Text(L("ask.history.empty"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 8)
            .animation(AskMotion.panelAnimation(reduceMotion: reduceMotion), value: model.selectedId)
            .background(AskHistoryPullRefresh(
                isRefreshing: model.isRefreshingHistory,
                onDistance: { pullDistance = $0 },
                onRefresh: { Task { await model.pullToRefreshHistory() } }
            ))
        }
        .overlay(alignment: .top) { pullIndicator }
        .clipped()
        .accessibilityAction(named: Text(L("ask.refresh"))) { Task { await model.pullToRefreshHistory() } }
    }

    private func groupHeader(_ title: String, first: Bool) -> some View {
        let collapsed = collapsedGroups.contains(title)
        return Button {
            if collapsed { collapsedGroups.remove(title) } else { collapsedGroups.insert(title) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, first ? 4 : 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Floats over the list (no layout shift). While pulling it sits in the gap the
    /// native rubber band opens; while refreshing or failed it rests at the top.
    @ViewBuilder private var pullIndicator: some View {
        let refreshing = model.isRefreshingHistory
        let failed = model.historyRefreshError != nil
        let progress = min(1, pullDistance / AskHistoryPullGesture.threshold)
        if refreshing || failed || pullDistance > 0 {
            HStack(spacing: 6) {
                if refreshing { ProgressView().controlSize(.mini) }
                else if failed { Image(systemName: "exclamationmark.circle") }
                else {
                    Image(systemName: "arrow.down")
                        .rotationEffect(.degrees(progress >= 1 ? 180 : 0))
                        .animation(.easeOut(duration: 0.15), value: progress >= 1)
                }
                Text(model.historyRefreshError ?? L(refreshing ? "ask.history.refreshing"
                        : progress >= 1 ? "ask.history.release" : "ask.history.pull"))
                    .lineLimit(2)
            }
            .font(.system(size: 11))
            .foregroundStyle(failed && !refreshing ? StudioTheme.warning : StudioTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(AskTheme.controlSurface, in: Capsule())
            .opacity(refreshing || failed ? 1 : progress)
            .offset(y: refreshing || failed ? 6 : max(0, pullDistance / 2 - 13))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func historyRow(_ item: AskConversationSummary) -> some View {
        AskHistoryRow(
            title: item.title,
            updatedAt: item.updatedAt,
            selected: model.selectedId == item.id,
            busy: model.busyIds.contains(item.id),
            local: marksLocalHistory && model.isLocal(item.id),
            work: item.resolvedKind == .work,
            host: model.hostElsewhere(item),
            selectionSpace: selectionSpace,
            onSelect: {
                showsSidebarDrawer = false
                Task { await model.select(item.id) }
            },
            onRename: { try await model.renameConversation(item.id, title: $0) },
            onOpenWorkspace: { Task { await model.openWorkspace(item.id) } },
            onDelete: { deleteId = item.id }
        )
    }

    // MARK: - Content

    /// The transcript fills the column and scrolls under the floating header
    /// and composer, so their glass has the conversation to refract. Its edges
    /// fade out where it meets the window instead of being cut by a rule.
    private var content: some View {
        ZStack(alignment: .top) {
            Group {
                if model.selectedId == nil {
                    emptyState.transition(.opacity)
                } else {
                    transcript.transition(.opacity)
                }
            }
            .animation(AskMotion.revealAnimation(reduceMotion: reduceMotion), value: model.selectedId == nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(AskEdgeFade(topClear: layout.compactContent || layout.isShort || !style.usesGlass
                ? AskMetrics.titleBarRowHeight : AskMetrics.headerCapsuleTop,
                bottomClear: layout.composerBottomInset,
                fade: AskMetrics.transcriptEdgeFade,
                topFade: style.usesGlass ? nil : 0))
            .overlay {
                if transcriptDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AskTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(AskTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .askAttachmentDrop(model: model, launcher: false, targeted: $transcriptDropTargeted)
            composerArea
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AskBottomChromeHeight.self, value: geometry.size.height)
                })
                .frame(maxHeight: .infinity, alignment: .bottom)
            header
        }
        .onPreferenceChange(AskBottomChromeHeight.self) { bottomChromeHeight = $0 }
        .onChange(of: model.searchRequest) { _ in openSearch() }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The title and the conversation's actions as two glass capsules over the
    /// transcript: the title carries the run's state as a dot and a summary;
    /// the actions capsule carries usage and browser controls.
    /// Classic puts the same controls on an opaque title row ruled off from the transcript.
    @ViewBuilder private var header: some View {
        Group {
            if layout.compactContent { compactHeader } else { spaciousHeader }
        }
        .background {
            if !style.usesGlass {
                AskClassic.canvas
                    .overlay(alignment: .bottom) { AskClassicDivider(axis: .horizontal) }
                    .allowsHitTesting(false)
            }
        }
    }

    private var titleFontSize: CGFloat { style.usesGlass ? 13.5 : 13 }

    /// Keep the essential actions in one row; the title yields before controls do.
    private var compactHeader: some View {
        HStack(spacing: 4) {
            if model.selectedId == nil {
                AskConversationKindSwitch(selection: model.conversationKind(launcher: false), compact: true) {
                    model.setConversationKind($0, launcher: false)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                Text(headerTitle ?? model.selected?.title ?? L("ask.new"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            headerAction(.usage, label: L("ask.usage.title"), active: showsUsage) { toggleUsage() }
                .accessibilityIdentifier("ask.workspace.usage")
            browserButton()
            Menu {
                Button(L("ask.search"), action: openSearch).keyboardShortcut("k", modifiers: .command)
                if model.isTemporaryComposer(launcher: false) {
                    Label(L("ask.storage.temporary"), systemImage: AskStorageKind.temporary.symbol)
                } else if model.isSignedIn, model.storesLocally(launcher: false) {
                    Label(L("ask.storage.local"), systemImage: "lock")
                }
                if canContinueAsWork {
                    Button(L("ask.kind.continueAsWork")) { model.continueInNew(.work) }
                }
                if let id = model.selectedId {
                    Button(L("ask.workspace.openFolder")) { Task { await model.openWorkspace(id) } }
                    Button(L("ask.delete"), role: .destructive) { deleteId = id }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("ask.search.actions"))
            .accessibilityIdentifier("ask.workspace.more")
        }
        .padding(.leading, AskMetrics.trafficLightInset + AskMetrics.titleBarButtonWidth * 2 + 18)
        .padding(.trailing, 10)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private var spaciousHeader: some View {
        HStack(spacing: 8) {
            if model.selectedId != nil {
                HStack(spacing: 10) {
                    if let marked = model.markedStorage(launcher: false) {
                        AskStorageTitleGlyph(kind: marked).padding(.trailing, -4)
                    }
                    Text(headerTitle ?? model.selected?.title
                        ?? model.conversations.first(where: { $0.id == model.selectedId })?.title
                        ?? L("ask.new"))
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    if model.isLoadingSelection, model.selected != nil { ProgressView().controlSize(.small) }
                    if layout.mainWidth >= 760, let phase = model.runPhase {
                        HStack(spacing: 5) {
                            AskRunToneDot(tone: phase.tone)
                            Text(phase.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                .padding(.leading, style.usesGlass ? 14 : 6)
                .padding(.trailing, style.usesGlass ? 16 : 6)
                .frame(height: AskMetrics.headerCapsuleHeight)
                .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            } else {
                Text(headerTitle ?? L("ask.new"))
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, style.usesGlass ? 16 : 6)
                    .frame(height: AskMetrics.headerCapsuleHeight)
                    .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            }
            Spacer(minLength: 8)
            switch model.markedStorage(launcher: false) {
            case .temporary: AskTemporaryChip(model: model, showsTitle: layout.mainWidth >= 760)
            case .local: AskLocalChip(model: model, showsTitle: layout.mainWidth >= 760)
            case .cloud, nil: EmptyView()
            }
            if model.selectedId != nil || model.tools.browserWorkspace != nil {
                HStack(spacing: 2) {
                    if model.selectedId != nil {
                        if canContinueAsWork {
                            AskHeaderIconButton(symbol: AskConversationKind.work.symbol,
                                                label: L("ask.kind.continueAsWork"), shortcut: nil) {
                                model.continueInNew(.work)
                            }
                            .accessibilityIdentifier("ask.workspace.continueAsWork")
                        }
                        AskHeaderIconButton(symbol: "folder", label: L("ask.workspace.openFolder"), shortcut: nil) {
                            if let id = model.selectedId { Task { await model.openWorkspace(id) } }
                        }
                        headerAction(.usage, label: L("ask.usage.title"), active: showsUsage) { toggleUsage() }
                            .accessibilityIdentifier("ask.workspace.usage")
                    }
                    browserButton(showsInteriorFill: model.selectedId != nil || !style.usesGlass)
                }
                .padding(.horizontal, 3)
                .frame(height: AskMetrics.headerCapsuleHeight)
                .frame(width: style.usesGlass && model.selectedId == nil
                    ? AskMetrics.headerCapsuleHeight : nil)
                .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            }
        }
        .padding(.leading, sidebarHidden ? AskMetrics.collapsedTitleInset : 14)
        .padding(.trailing, 14)
        .frame(height: AskMetrics.titleBarRowHeight)
        .overlay {
            if model.selectedId == nil { kindSwitch }
        }
    }

    /// Chat or work for the conversation about to start, like ChatGPT's switch.
    private var kindSwitch: some View {
        AskConversationKindSwitch(selection: model.conversationKind(launcher: false)) { kind in
            withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) {
                model.setConversationKind(kind, launcher: false)
            }
        }
    }

    @ViewBuilder private func browserButton(showsInteriorFill: Bool = true) -> some View {
        if model.tools.browserWorkspace != nil {
            AskHeaderIconButton(symbol: model.selectedId == nil ? "sidebar.right" : "globe",
                                label: L(model.selectedId == nil ? "ask.sidebar.right.toggle" : "ask.web.title"),
                                shortcut: "⌘⇧B",
                                active: showsBrowserPanel, showsInteriorFill: showsInteriorFill) {
                setBrowser(!showsBrowserPanel)
            }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .accessibilityIdentifier("ask.workspace.browser")
        }
    }

    /// A started chat this Mac can continue offers to carry on as work.
    private var canContinueAsWork: Bool {
        model.selected != nil && model.selectedHostElsewhere == nil && model.conversationKind(launcher: false) == .chat
    }

    /// A temporary conversation is never named, a new one is just "Temporary chat".
    private var headerTitle: String? {
        model.isTemporaryComposer(launcher: false) ? L("ask.temporary.title") : nil
    }

    /// The header icon and the composer's context ring both toggle the panel:
    /// the same control that opened it closes it again.
    private func toggleUsage() {
        if !showsUsage { usageRunId = model.selected?.run?.id }
        setUsage(!showsUsage)
    }

    /// The usage panel slides in from the trailing edge like the sidebar.
    private func setUsage(_ shown: Bool) {
        guard shown != showsUsage else { return }
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            showsSidebarDrawer = false
            isSearching = false
            showsUsage = shown
            if shown { showsBrowser = false }
        }
    }

    private func headerAction(_ kind: AskLineGlyph.Kind, label: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        AskHeaderLineButton(kind: kind, label: label, active: active, action: action)
    }

    private var emptyState: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    if !layout.isShort {
                        AskEmptyStateOrb(voice: model.voiceInput,
                                         palette: .init(marked: model.markedStorage(launcher: false)))
                            .padding(.bottom, 20)
                    }
                    if !layout.isVeryShort {
                        Text(L(model.conversationKind(launcher: false) == .work ? "ask.empty.work" : "ask.empty"))
                            .font(.system(size: layout.isShort ? 20 : 26, weight: .bold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .padding(.bottom, 9)
                    }
                    if !layout.isShort { emptyHint }
                    if hasStatus {
                        statusColumn
                            .frame(maxWidth: AskMetrics.transcriptMaxWidth)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.vertical, layout.isShort ? 6 : 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, viewport.size.height - AskMetrics.titleBarRowHeight - bottomChromeHeight))
            }
            .padding(.top, AskMetrics.titleBarRowHeight)
            .padding(.bottom, bottomChromeHeight)
        }
    }

    /// Summon and voice shortcuts, read from the configured hotkeys.
    private var emptyHint: some View {
        AskShortcutHint(settings: model.modelLibrary.settings)
    }

    /// Conversation events: they read in the transcript after the answer they
    /// belong to, never around the composer.
    private var statusColumn: some View {
        VStack(spacing: 10) { statusArea }
            .frame(maxWidth: AskMetrics.transcriptMaxWidth)
    }

    /// Whether `statusArea` shows anything, so an empty one adds no gap to the transcript.
    private var hasStatus: Bool {
        model.visibleVisionSwitch != nil || model.error != nil || model.imageRecoveryTarget != nil
            || (stoppedRun && !stepLimitEnded) || resumable || model.hasRecoveryNotice || creditPaused
    }

    /// The selected run stopped at the step limit and the user chose to end it there.
    private var stepLimitEnded: Bool {
        guard let run = model.selected?.run else { return false }
        return AskStepLimitPrompt.applies(run) && endedStepLimitRunId == run.id
    }

    /// The selected run waits for credits; its card replaces the generic resume hint.
    private var creditPaused: Bool { model.selected?.run?.isPausedForCredits == true }

    /// The selected run failed or was stopped, and nothing is about to resume it.
    private var stoppedRun: Bool {
        guard !model.hasPendingSubmission, !model.isBusy, let run = model.selected?.run else { return false }
        return run.status == "failed" || run.status == "cancelled"
    }

    @ViewBuilder private var statusArea: some View {
        if creditPaused {
            AskCreditPauseSection(model: model, auth: auth)
        }
        if model.hasRecoveryNotice, let value = model.selected, !model.busyIds.contains(value.id) {
            AskRecoveryCard(
                presentation: model.recoveryPresentation,
                canRetransmit: model.canRetransmitReceipts,
                canContinue: model.recoveryPresentation.canContinue && !model.canRetransmitReceipts,
                working: model.recoveryWorking,
                inspect: { model.inspectingRecovery = true },
                perform: { model.performRecovery($0) }
            )
        }
        if let change = model.visibleVisionSwitch {
            let library = model.modelLibrary
            AskSystemLine(text: String(format: L("ask.vision.switched"), library.name(for: change.to)),
                          systemImage: "eye",
                          actionTitle: String(format: L("ask.vision.revert"), library.name(for: change.from)),
                          action: { model.revertVisionSwitch() },
                          onDismiss: { model.visionSwitch = nil })
        }
        if model.imageRecoveryTarget == nil, let error = model.error,
           !model.submissionIssues.values.contains(where: { $0.text == error }),
           !model.hasRecoveryNotice || error != L("ask.recovery.unknownBody") {
            let storageFailure = error == L("ask.cache.failed")
            let recoveryReadFailure = model.selectedRecoveryEntries.contains(where: \.readUnavailable)
            AskBanner(
                text: error,
                tone: .warning,
                actionTitle: recoveryReadFailure ? L("ask.retry") : storageFailure ? L("feedback.direct.title")
                    : (model.selectionLoadFailed || !model.hasRecoveryNotice ? L("ask.retry") : nil),
                action: {
                    if recoveryReadFailure { model.retrySelection() }
                    else if storageFailure { model.onOpenFeedback?() }
                    else if model.selectionLoadFailed { model.retrySelection() }
                    else { model.resume() }
                },
                onDismiss: { model.error = nil }
            )
        }
        if let target = model.imageRecoveryTarget {
            AskImageRecoveryCard(model: model, target: target)
                .id(target.id)
        } else if stoppedRun, !model.hasRecoveryNotice, let value = model.selected,
                  !model.recoveryBlocksResume(value), let run = value.run, AskStepLimitPrompt.applies(run) {
            if endedStepLimitRunId != run.id {
                AskStepLimitPrompt(steps: run.steps, plan: run.plan,
                                   onEnd: { endedStepLimitRunId = run.id },
                                   onContinue: { model.resume() })
            }
        } else if stoppedRun, !model.hasRecoveryNotice, let value = model.selected,
                  !model.recoveryBlocksResume(value), let run = value.run {
            AskBanner(text: run.failureLocalizationKey.map { L($0) } ?? run.error ?? L("ask.cancelled"), tone: .info,
                      systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
        } else if resumable, !model.hasRecoveryNotice, model.error == nil {
            AskBanner(text: L("ask.resume.hint"), tone: .info, systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
        }
    }

    /// An interrupted run: either the request never started, or it is still
    /// active on this conversation while no local operation is driving it.
    private var resumable: Bool {
        guard let selected = model.selected, !model.isBusy else { return false }
        if model.hasPendingSubmission { return true }
        if creditPaused { return false }
        if selected.run == nil, selected.messages.last?.role == "user" { return true }
        return selected.run?.isActive == true && !model.busyIds.contains(selected.id)
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            // Stop lives in the send button's place while the run works.
            // The context budget used to occupy a whole row of its own below the
            // composer; it now rides in the footer next to the send button.
            // Nothing sits under the card: its shortcuts are in the placeholder
            // and on the send and microphone buttons' help.
            if let suggestion = model.offlineSuggestion(launcher: false) {
                AskOfflineNotice(suggestion: suggestion, library: model.modelLibrary) {
                    model.applyOfflineSuggestion(suggestion, launcher: false)
                }
            }
            if let host = model.selectedHostElsewhere {
                // Another device runs it; this Mac only reads its synchronized history.
                AskHostElsewhereNotice(host: host, kind: model.conversationKind(launcher: false)) {
                    model.continueInNewChat()
                }
            } else {
                AskComposer(model: model, compact: layout.isShort, availableWidth: layout.composerWidth,
                            availableHeight: layout.composerAvailableHeight,
                            launcher: false, onToggleUsage: { toggleUsage() })
                    .disabled(model.isLoadingSelection)
            }
        }
        .frame(maxWidth: AskMetrics.composerMaxWidth)
        .padding(.horizontal, layout.compactContent ? 12 : 22)
        .padding(.top, layout.composerTopInset)
        .padding(.bottom, layout.composerBottomInset)
    }

    /// The decision sits at the end of the conversation it belongs to.
    private func approval(_ call: AskToolCall, id: String) -> some View {
        approvalCard(call, id: id, embedded: false)
            .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
    }

    private func approvalCard(_ call: AskToolCall, id: String, embedded: Bool) -> AskApprovalCard {
        let approvalID = model.approvalID(id)
        return AskApprovalCard(
            call: call, risk: model.approvalRisk(id) ?? .destructive,
            mcpServer: model.mcpServerName(of: call),
            targetSummary: model.approvalTarget(id),
            reason: Self.approvalReason(call, messages: model.selected?.messages ?? []),
            canAllowForConversation: model.canAllowForConversation(id),
            embedded: embedded,
            onDeny: { model.approve(conversationId: id, allowed: false, expectedApprovalID: approvalID) },
            onAllowForConversation: { model.approveForConversation(id, expectedApprovalID: approvalID) },
            onAllow: { model.approve(conversationId: id, allowed: true, expectedApprovalID: approvalID) })
    }

    /// The narration the model wrote with the call awaiting approval: why it wants the step.
    static func approvalReason(_ call: AskToolCall, messages: [AskMessage]) -> String? {
        let text = messages.last { message in
            message.role == "assistant" && (message.toolCalls ?? []).contains { $0.id == call.id }
        }?.text
        return text?.isEmpty == false ? text : nil
    }

    /// When a transcript row first appeared: its message's time, or its first step's.
    static func createdAt(_ item: AskTranscriptItem) -> Date? {
        switch item.kind {
        case let .message(message): return message.createdAt
        case let .activity(group): return group.messages.first?.createdAt
        }
    }

    /// Whether a tool card in the transcript holds the call awaiting approval.
    static func groupContains(_ items: [AskTranscriptItem], callId: String) -> Bool {
        items.contains { item in
            if case let .activity(group) = item.kind { return group.calls.contains { $0.id == callId } }
            return false
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        // Resolved once per render: asking each row would rescan the transcript.
        let regenerable = model.regenerableAnswerId
        let items = AskActivity.items(transcriptMessages, results: model.selected?.messages.filter { $0.role == "tool" } ?? [])
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(items) { item in
                            transcriptRow(item, items: items, regenerable: regenerable)
                                .askRiseIn(createdAt: Self.createdAt(item))
                                .id(item.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: AskTranscriptFrames.self,
                                                           value: [item.id: geometry.frame(in: .named("ask-transcript"))])
                                })
                        }
                        if model.showsResponseWaiting {
                            AskResponseWaitingView()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("response-waiting")
                        }
                        // A decision for a step in a tool card sits inside that card.
                        if let id = model.selected?.id, let call = model.pendingApprovals[id],
                           !Self.groupContains(items, callId: call.id) {
                            approval(call, id: id).id("approval-" + call.id)
                        }
                        // Jumped messages wait after everything the run still has to finish.
                        ForEach(steeredMessages) { message in
                            AskMessageView(message: message, steeredPending: true, onReference: { _ in }).id(message.id)
                        }
                        // Errors, interrupted runs and model switches follow the last answer.
                        if hasStatus { statusColumn.id("status") }
                        // The draft follows what happened to the run that wrote it.
                        if let session = model.authoringSession {
                            AskWorkflowAuthoringCard(session: session, selected: showsWorkflow, open: {
                                showsUsage = false
                                session.isPresented = true
                                model.objectWillChange.send()
                            }, close: {
                                session.isPresented = false
                                model.objectWillChange.send()
                            })
                        }
                        // The end marker spans the space under the composer, so
                        // scrolling to it leaves the last answer above the card.
                        Color.clear.frame(height: bottomChromeHeight + 1).id("bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AskTranscriptFrames.self,
                                                       value: ["bottom": geometry.frame(in: .named("ask-transcript"))])
                            })
                    }
                    // One centred column: the question, the answer and the
                    // composer below share the same edges on any window width.
                    .padding(.horizontal, layout.horizontalInset)
                    .padding(.top, AskMetrics.titleBarRowHeight + 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: AskMetrics.columnWidth)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "ask-transcript")
                // Hidden until it sits at its reading position, then faded in:
                // drawing first and scrolling a frame later made every load
                // flash the top of the conversation before jumping to the end.
                .opacity(restoredTranscript != nil && restoredTranscript == model.selectedId ? 1 : 0)
                .overlay(alignment: .top) {
                    if model.isLoadingSelection, model.selected == nil {
                        AskDelayedProgress(title: L("ask.loading"))
                            .padding(.top, AskMetrics.titleBarRowHeight + 24)
                    }
                    // Nothing loaded to follow: the failure takes the transcript's place.
                    if model.selectionLoadFailed, model.selected == nil, let error = model.error {
                        AskBanner(text: error, tone: .warning, actionTitle: L("ask.retry"),
                                  action: { model.retrySelection() })
                            .frame(maxWidth: AskMetrics.transcriptMaxWidth)
                            .padding(.horizontal, AskMetrics.columnInset)
                            .padding(.top, AskMetrics.titleBarRowHeight + 24)
                    }
                }
                .onPreferenceChange(AskTranscriptFrames.self) { frames in
                    guard let id = model.selectedId, restoredTranscript == id else { return }
                    // A resize can move the end marker before ScrollView adjusts
                    // its offset. Preserve the existing reading intent for that
                    // layout pass instead of interpreting it as a manual scroll.
                    if transcriptViewportSize != viewport.size || transcriptCoveredBottom != bottomChromeHeight {
                        transcriptViewportSize = viewport.size
                        transcriptCoveredBottom = bottomChromeHeight
                        followBottom(proxy, afterLayoutChange: true)
                        return
                    }
                    if let bottom = frames["bottom"], AskPresentation.isFollowingBottom(
                        markerTop: bottom.minY, viewport: viewport.size.height, coveredBottom: bottomChromeHeight) {
                        model.transcriptPositions[id] = "bottom"
                    } else if let first = frames.filter({ $0.key != "bottom" && $0.value.maxY > 0 })
                        .min(by: { $0.value.minY < $1.value.minY }) {
                        model.transcriptPositions[id] = first.key
                    }
                }
                .onChange(of: model.referenceLocation) { id in
                    // A step folded into an activity block scrolls to its block.
                    if let id {
                        let target = items.first { item in
                            if case let .activity(group) = item.kind { return group.messageIds.contains(id) }
                            return false
                        }?.id ?? id
                        proxy.scrollTo(target, anchor: .center); model.referenceLocation = nil
                    }
                }
                .onChange(of: model.selectedId) { _ in restoredTranscript = nil }
                .onChange(of: model.selected?.id) { _ in restoreTranscript(proxy) }
                .onAppear { restoreTranscript(proxy) }
                .onChange(of: viewport.size) { _ in followBottom(proxy, afterLayoutChange: true) }
                .onChange(of: bottomChromeHeight) { _ in followBottom(proxy, afterLayoutChange: true) }
                .onChange(of: model.selected?.run?.preview) { _ in followBottom(proxy) }
                .onChange(of: model.inferenceProgress) { _ in followBottom(proxy) }
                .onChange(of: model.selected?.messages.count) { _ in followBottom(proxy) }
                .onChange(of: model.showsResponseWaiting) { _ in followBottom(proxy) }
                .onChange(of: model.selectedId.flatMap { model.pendingApprovals[$0]?.id }) { _ in followBottom(proxy) }
                .onChange(of: model.steeredMessages.count) { _ in followBottom(proxy) }
                .onChange(of: hasStatus) { _ in followBottom(proxy) }
                .onChange(of: model.error) { _ in followBottom(proxy) }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: AskTranscriptItem, items: [AskTranscriptItem], regenerable: String?) -> some View {
        let run = model.selected?.run
        let phase = model.runPhase
        let streamingId = phase?.isWorking == true ? run?.assistantId : nil
        let approvalToolId = model.selectedId.flatMap { model.pendingApprovals[$0]?.id }
        switch item.kind {
        case let .message(message):
            AskMessageView(message: message,
                           onReference: { model.addReference($0) },
                           onLocate: model.locateReference,
                           usage: message.runId.flatMap { model.selected?.usage?.runs[$0] },
                           onUsage: { usageRunId = message.runId; setUsage(true) },
                           isStreaming: message.id == streamingId,
                           canRegenerate: regenerable == message.id,
                           onRegenerate: { model.regenerate(message.id) },
                           outputs: item.outputs,
                           onSaveNote: model.notes == nil || message.role != "assistant" ? nil
                               : { excerpt in model.performNotebookAction { await model.toggleAnswerNote(message, excerpt: excerpt) } },
                           savedToNotes: model.answerNoteIDs[message.id] != nil)
        case let .activity(group):
            let results = model.selected?.messages.filter { $0.role == "tool" } ?? []
            let isLatest = items.last(where: { if case .activity = $0.kind { return true }; return false })?.id == group.id
            // The run's latest block stays live between steps, while no answer follows it yet,
            // and stops spinning with every other indicator once the run waits for a decision.
            let carriesRun = run?.isActive == true && items.last?.id == group.id
            let halted: Bool = {
                switch phase {
                case .needsDecision?, .pausedCredits?, .waitingDevice?: break
                default: return false
                }
                guard isLatest else { return false }
                return group.messages.contains { $0.runId == nil || $0.runId == run?.id }
            }()
            let live = phase?.isWorking == true && carriesRun
            let status = AskActivity.status(group, results: results, streamingId: streamingId,
                                            approvalToolId: approvalToolId, live: live, halted: halted)
            let pending = model.selectedId.flatMap { id in
                model.pendingApprovals[id].map { (id: id, call: $0) }
            }
            AskActivityBlock(group: group, results: results,
                             plan: AskActivity.plan(for: group, run: run, isLatest: isLatest),
                             status: status, streamingId: streamingId, approvalToolId: approvalToolId,
                             runStep: live || halted ? phase?.step : nil,
                             outputs: item.outputs,
                             approval: pending.flatMap { pending in
                                 group.calls.contains { $0.id == pending.call.id }
                                     ? AnyView(approvalCard(pending.call, id: pending.id, embedded: true)) : nil
                             }, exportProjectPatch: model.exportProjectPatch)
                .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
        }
    }

    /// Jumped messages the run has not read yet, as user turns.
    private var steeredMessages: [AskMessage] {
        model.steeredMessages.map { item in
            let request = item.draft.request(deviceId: model.deviceId, tools: [], id: item.id)
            return AskMessage(id: item.id, role: "user", text: request.text, selection: request.selection, source: request.source,
                              image: request.image, createdAt: Date(), references: request.references, steered: true,
                              attachments: request.attachments, mcpServers: request.mcpServers)
        }
    }

    private var transcriptMessages: [AskMessage] {
        guard let value = model.selected else { return [] }
        var messages = value.messages.filter { $0.role != "tool" }
        if let progress = model.liveProgress(value), let run = value.run {
            let id = run.assistantId ?? "live-" + run.id
            if !messages.contains(where: { $0.id == id }) {
                messages.append(.init(id: id, role: "assistant", text: progress.text,
                                      toolCalls: progress.toolCalls, createdAt: run.updatedAt,
                                      reasoning: progress.reasoning, reasoningMilliseconds: progress.reasoningMilliseconds))
            }
        }
        return messages
    }

    private func followBottom(_ proxy: ScrollViewProxy, afterLayoutChange: Bool = false) {
        // Resizing is itself a mouse drag. Keep following through those geometry
        // changes while ordinary streamed updates still respect text selection.
        guard afterLayoutChange || NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? AskTranscriptText.Editor,
           editor.selectedRange().length > 0 { return }
        guard let id = model.selectedId, restoredTranscript == id,
              model.transcriptPositions[id] == "bottom" else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func restoreTranscript(_ proxy: ScrollViewProxy) {
        guard let id = model.selected?.id, restoredTranscript != id else { return }
        let anchor = model.transcriptPositions[id] ?? "bottom"
        model.transcriptPositions[id] = anchor
        DispatchQueue.main.async {
            guard model.selectedId == id else { return }
            proxy.scrollTo(anchor, anchor: anchor == "bottom" ? .bottom : .top)
            // One more pass lets the lazy rows settle at the new offset before revealing.
            DispatchQueue.main.async {
                guard model.selectedId == id else { return }
                withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) { restoredTranscript = id }
            }
        }
    }
}

/// User turns are right-aligned bubbles, assistant turns are signed paragraphs.
/// The role is carried by the layout, not by a grey "You" label.
private struct AskMessageView: View {
    let message: AskMessage
    /// A jumped message the running run has not read yet.
    var steeredPending = false
    var onReference: (AskReference) -> Void
    /// Scrolls to the answer a sent quote came from.
    var onLocate: (String) -> Void = { _ in }
    var usage: AskUsageTotals? = nil
    var onUsage: () -> Void = {}
    var isStreaming = false
    var canRegenerate = false
    var onRegenerate: () -> Void = {}
    /// Images and pages from the tool steps before this answer.
    var outputs = AskRunOutputs()
    /// Saves the answer, or the given part of it, to the notebook; nil hides the action.
    var onSaveNote: ((String?) -> Void)?
    /// The whole answer is in the notebook.
    var savedToNotes = false
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        if message.role == "user" { userMessage } else if message.role != "tool" { assistantMessage }
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if let references = message.references, !references.isEmpty {
                    AskSentReferences(references: references, locate: onLocate)
                }
                if let files = message.attachments, !files.isEmpty {
                    AskFlowLayout(spacing: 6, alignment: .trailing) {
                        ForEach(files) { AskSentFileChip(attachment: $0) }
                    }
                }
                let tools = (message.skills ?? []).map { AskChosenTool(kind: .skill, name: $0.name) }
                    + (message.mcpServers ?? []).map { AskChosenTool(kind: .mcpServer, name: $0) }
                if !tools.isEmpty {
                    AskFlowLayout(spacing: 6, alignment: .trailing) {
                        ForEach(tools) { tool in
                            AskSentAttachmentChip(title: tool.caption + " · " + tool.name, systemImage: tool.symbol)
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(StudioTheme.textPrimary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(AskTheme.userBubble, in: AskBubbleShape(radius: 20, tail: 6))
                        .overlay(AskBubbleShape(radius: 20, tail: 6)
                            .strokeBorder(AskTheme.userBubbleEdge, lineWidth: 0.5))
                }
                AskMessageProvenanceView(message: message)
                if message.steered == true {
                    Label(L(steeredPending ? "ask.steered.pending" : "ask.steered"), systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .frame(maxWidth: AskMetrics.bubbleMaxWidth, alignment: .trailing)
        }
    }

    /// No avatar, no product name, no timestamp: there is only one assistant in
    /// this window, so that row was chrome competing with the answer. Copy,
    /// quote and usage move into a toolbar that fades in under the pointer.
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                AskReasoningView(text: reasoning, milliseconds: message.reasoningMilliseconds ?? 0,
                                 active: isStreaming && message.text.isEmpty)
            }
            if !message.text.isEmpty {
                AskMermaidTranscript(text: message.text, isStreaming: isStreaming,
                                     onAsk: isStreaming ? nil : { text, question in
                    onReference(AskReference(messageId: message.id, text: text, question: question))
                }, onSaveNote: isStreaming ? nil : onSaveNote.map { save -> (String) -> Void in { save($0) } })
                .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
            }
            if !outputs.isEmpty, !isStreaming {
                AskRunOutputsView(outputs: outputs)
                    .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
            }
            if message.isError == true { interruptedTag }
            if !message.text.isEmpty, !isStreaming { turnActions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    /// A small tag instead of a loose grey line. When the answer can be
    /// produced again, the tag carries that action itself.
    private var interruptedTag: some View {
        HStack(spacing: 6) {
            Circle().fill(StudioTheme.warning).frame(width: 6, height: 6)
            Text(L("ask.answer.interrupted"))
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
            if canRegenerate, !isStreaming {
                Button(action: onRegenerate) {
                    Text(L("ask.regenerate"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AskTheme.accentText)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(AskTheme.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canRegenerate && !isStreaming ? 3 : 10)
        .frame(height: 26)
        .background(AskTheme.hoverFill, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    /// The row keeps its height while hidden, so hovering never reflows the
    /// transcript under the pointer. Opacity (not a conditional view) also keeps
    /// the actions reachable by VoiceOver and the keyboard at all times.
    private var turnActions: some View {
        HStack(spacing: 2) {
            AskIconGhostButton(label: copied ? L("ask.copied") : L("ask.copy"),
                               systemImage: copied ? "checkmark" : "doc.on.doc", active: copied) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            // An interrupted answer already offers this on its tag.
            if canRegenerate, message.isError != true {
                AskIconGhostButton(label: L("ask.regenerate"), systemImage: "arrow.clockwise", action: onRegenerate)
            }
            AskIconGhostButton(label: L("ask.quote"), systemImage: "text.quote") {
                onReference(AskReference(messageId: message.id, text: message.text, question: ""))
            }
            if let onSaveNote {
                AskIconGhostButton(label: L(savedToNotes ? "ask.notes.savedAnswer" : "ask.notes.saveAnswer"),
                                   systemImage: savedToNotes ? "note.text" : "note.text.badge.plus",
                                   active: savedToNotes) { onSaveNote(nil) }
                    .accessibilityIdentifier("ask.message.saveNote")
            }
            AskIconGhostButton(label: usageHelp, systemImage: "chart.bar.xaxis", action: onUsage)
            .accessibilityLabel(L("ask.usage.title"))
            .accessibilityValue(usageLabel)
        }
        .opacity(hovering || copied || savedToNotes ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var usageLabel: String {
        guard let usage else { return L("ask.usage.title") }
        if usage.calls > 0, usage.external == usage.calls { return usage.tokenText(usage.totalTokens) + " tokens" }
        return usage.creditsText + " credits"
    }

    private var usageHelp: String {
        guard usage != nil else { return L("ask.usage.title") }
        return L("ask.usage.title") + " · " + usageLabel
    }
}

/// Reasoning is a single quiet line above the answer. It used to take a full
/// disclosure row plus a boxed body; now it only costs height once expanded.
struct AskReasoningView: View {
    let text: String
    let milliseconds: Int
    let active: Bool
    @State private var expanded = false
    @State private var reasoningHover = false

    private var label: String {
        active ? L("ask.reasoning.active") : L("ask.reasoning.complete", max(1, milliseconds / 1000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(StudioTheme.aiIcon).font(.system(size: 11))
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .modifier(AskShimmer(active: active))
                    if !active {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(height: 26)
                .background(reasoningHover ? AskTheme.hoverFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { reasoningHover = $0 }
            .padding(.leading, -8)
            .accessibilityLabel(label)
            if expanded {
                AskReasoningText(text: text)
                    .frame(height: 220)
                    .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(AskTheme.border).frame(width: 2) }
            }
        }
        .onChange(of: active) { value in if !value { expanded = false } }
    }
}

private struct AskTranscriptFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A file, image or folder sent with a question. Images and text open a preview;
/// a folder shows its location in Finder.
struct AskSentFileChip: View {
    let attachment: AskAttachment
    @State private var previewing = false
    @StateObject private var imageModel = AskContextImageModel()
    @Environment(\.askContextImageAccess) private var imageAccess
    private var thumbnail: NSImage? { imageModel.displayed(attachment.image, access: imageAccess) }

    var body: some View {
        Button {
            if attachment.kind == .folder, let path = attachment.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                previewing = true
            }
        } label: {
            AskSentAttachmentChip(
                title: [attachment.name, AskAttachmentStrip.caption(attachment)].compactMap { $0 }.joined(separator: " · "),
                thumbnail: thumbnail,
                systemImage: AskAttachmentStrip.symbol(attachment)
            )
            .frame(maxWidth: 260)
        }
        .buttonStyle(.plain)
        .help(attachment.path ?? attachment.name)
        .popover(isPresented: $previewing) { preview }
        .task(id: AskContextImageModel.Identity(source: attachment.image, epoch: imageAccess.epoch)) {
            await imageModel.load(attachment.image, access: imageAccess)
        }
        .onDisappear { imageModel.cancel(); previewing = false }
    }

    @ViewBuilder private var preview: some View {
        if let image = thumbnail {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 650, maxHeight: 520).padding()
        } else if attachment.image != nil {
            Text(L("ask.image.previewUnavailable")).padding()
        } else {
            ScrollView {
                Text(String((attachment.text ?? "").prefix(20000)))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 320)
            .padding(14)
        }
    }
}
