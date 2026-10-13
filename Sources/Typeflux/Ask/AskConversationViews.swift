// swiftlint:disable file_length type_body_length
import AppKit
import SwiftUI

struct AskConversationView: View {
    @ObservedObject var model: AskConversationModel
    @StateObject private var presentation: AskWorkspaceState
    @State private var deleteId: String?
    @State private var pullDistance: CGFloat = 0
    @State private var restoredTranscript: String?
    @StateObject private var toolbarSearch = TypefluxSearchState()
    @State private var collapsedGroups: Set<String> = []
    /// Which conversations the sidebar lists while some are kept on this Mac.
    @State private var historyFilter = AskHistoryFilter.all
    @Namespace private var selectionSpace
    /// Height of the banners and composer floating over the transcript's bottom edge.
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var transcriptViewportSize: CGSize = .zero
    @State private var transcriptCoveredBottom: CGFloat = 0
    /// Files are dragged over the transcript; they attach to the draft when dropped.
    @State private var transcriptDropTargeted = false
    /// The presentation's sidebar choice drives the animated layout; this preference
    /// supplies the initial choice for future windows.
    @AppStorage("ask.sidebarCollapsed") private var storedSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceStyle) private var style
    @State private var windowSize = AskWorkspaceLayout.minimumWindowSize
    @FocusState private var drawerCloseFocused: Bool
    @State private var previousResponder: NSResponder?
    @ObservedObject private var auth: AuthState

    @MainActor
    init(model: AskConversationModel, showsUsage: Bool = false, auth: AuthState? = nil,
         presentation: AskWorkspaceState? = nil) {
        self.model = model
        self.auth = auth ?? .shared
        _presentation = StateObject(wrappedValue: presentation ?? AskWorkspaceState(
            showsUsage: showsUsage, runId: model.selected?.run?.id
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            workspace
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { windowSize = geometry.size }
                .onChange(of: geometry.size) { windowSize = $0 }
        }
        // Measure the viewport, rather than the intrinsic width of its children.
        .onChange(of: model.selectedId) { _ in
            presentation.usageRunId = nil
            presentation.showsUsage = false
            presentation.showsSidebarDrawer = false
        }
        .onChange(of: model.authoringSession?.revision) { _ in
            if model.authoringSession?.isPresented == true { presentation.showsUsage = false }
        }
        .onChange(of: layout.sidebarInline) { inline in
            if inline { presentation.showsSidebarDrawer = false }
        }
        .onChange(of: layout.usageOverlay) { overlay in
            // A resize must not queue a second drawer behind the open history.
            if overlay, presentation.showsSidebarDrawer { presentation.showsUsage = false }
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
        .tint(TypefluxColor.accent.color)
        .environment(\.askUsesLibraryTokens, true)
        .environment(\.askComposerFocusRequest, presentation.composerFocusRequestID)
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
                           showsUsage: presentation.showsUsage || showsWorkflow,
                           rightPanelWidth: showsWorkflow ? 390 : nil)
    }

    private var showsWorkflow: Bool { model.authoringSession?.isPresented == true && !presentation.showsUsage }

    @ViewBuilder private var rightPanel: some View {
        if showsWorkflow, let session = model.authoringSession {
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
                          floating: layout.usageOverlay, runId: $presentation.usageRunId, close: { setUsage(false) })
        }
    }

    private var hasDrawer: Bool { presentation.showsSidebarDrawer || layout.usageOverlay }
    private var hasModal: Bool { hasDrawer || presentation.isSearching }

    private var workspace: some View {
        ZStack(alignment: .topLeading) {
            workspaceWindow
                .background { workspaceShortcuts }
                .disabled(hasModal)
                .accessibilityHidden(hasModal)
            if hasDrawer { drawer }
            if presentation.isSearching { searchPalette }
        }
        .clipped()
    }

    /// Ask owns panel animation and persistence; the library supplies native controls and surfaces.
    private var workspaceWindow: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if !sidebarHidden {
                    sidebar
                        .frame(width: AskMetrics.sidebarWidth)
                        .askSidePanel(edge: .leading, glassFill: LegacyAskPalette.glassFill,
                                      glassInset: [.top, .leading, .bottom])
                        .transition(AskMotion.panel(edge: .leading, reduceMotion: reduceMotion))
                }
                HStack(spacing: 0) {
                    content
                    if layout.usageInline {
                        rightPanel.id(model.selectedId)
                            .transition(AskMotion.panel(edge: .trailing, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TypefluxColor.contentBackground.color)
            }
            .typefluxSearchable(state: toolbarSearch, prompt: L("ask.search.conversations"))
            .navigationTitle("")
            .typefluxWindowChrome(title: workspaceTitle, actionTitles: [L("ask.sidebar.toggle"), L("ask.new")],
                                  trailingItemIdentifiers: ["ask.workspace.status", "ask.actions", "ask.workspace.new"])
            .toolbar {
                ToolbarItem(id: "ask.workspace.sidebar", placement: .navigation) {
                    TypefluxIconButton(L("ask.sidebar.toggle"), systemImage: "sidebar.left", action: toggleSidebar)
                        .frame(width: TypefluxControlWidth.toolbarItem.value(for: style),
                               height: TypefluxControlHeight.toolbarItem.value(for: style))
                        .keyboardShortcut("s", modifiers: [.command, .control])
                        .accessibilityIdentifier("ask.workspace.sidebar")
                }
                TypefluxToolbarTitle(workspaceTitle, width: toolbarTitleWidth)
                #if compiler(>=6.2)
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                #endif
                if let center = toolbarCenter {
                    ToolbarItem(id: "ask.workspace.status", placement: .primaryAction) {
                        center
                            .frame(width: toolbarStatusWidth,
                                   height: TypefluxControlHeight.toolbarItem.value(for: style))
                    }
                }
                TypefluxToolbar(groups: toolbarGroups, prominent: newConversationAction, separatesProminent: true)
            }
            .toolbarBackground(TypefluxColor.windowBackground.color, for: .windowToolbar)
            .toolbarBackground(style.usesGlass ? .automatic : .visible, for: .windowToolbar)
        }
    }

    private var toolbarTitleWidth: CGFloat {
        let itemWidth = TypefluxControlWidth.toolbarItem.value(for: style)
        let actions = toolbarGroups.flatMap(\.actions).count + 2
        let statusWidth: CGFloat = toolbarCenter == nil ? 0 : (layout.compactContent ? itemWidth : 180) + 8
        let searchWidth = toolbarSearch.isExpanded ? TypefluxControlWidth.toolbarSearch.value(for: style) : itemWidth
        let reserved = 110 + CGFloat(actions) * (itemWidth + 8) + statusWidth + searchWidth + 8
        return max(1, min(220, windowSize.width - reserved))
    }

    private var toolbarStatusWidth: CGFloat {
        layout.compactContent ? TypefluxControlWidth.toolbarItem.value(for: style) : 180
    }

    // MARK: - Sidebar

    /// The user's choice: this window's latest toggle, else the stored preference.
    private var sidebarCollapsed: Bool { presentation.sidebarChoice ?? storedSidebarCollapsed }

    /// Hidden by the user, or stepping aside while the usage panel needs the
    /// room: three columns overflowed a narrow window and pushed the sidebar
    /// against its edge.
    private var sidebarHidden: Bool { !layout.sidebarInline }

    private var drawer: some View {
        ZStack(alignment: presentation.showsSidebarDrawer ? .leading : .trailing) {
            Color.black.opacity(0.24)
                .contentShape(Rectangle())
                .onTapGesture { closeDrawer() }
                .accessibilityHidden(true)
            if presentation.showsSidebarDrawer {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("ask.search.conversations")).font(.body).fontWeight(.semibold)
                        Spacer()
                        TypefluxIconButton(L("ask.artifact.close"), systemImage: "xmark", action: closeDrawer)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel(L("ask.artifact.close"))
                            .accessibilityIdentifier("ask.workspace.drawer.close")
                            .focused($drawerCloseFocused)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .frame(height: style.usesGlass ? 40 : AskMetrics.titleBarRowHeight)
                    TypefluxInlineSearch(text: $toolbarSearch.query, prompt: L("ask.search.conversations"))
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    if showsHistoryFilter { historyFilterPicker.padding(.horizontal, 10).padding(.bottom, 8) }
                    historyList
                    accountFooter
                }
                .frame(width: min(AskMetrics.sidebarWidth, layout.drawerWidth))
                .askSidePanel(edge: .leading, glassFill: LegacyAskPalette.glassFill, glassInset: .all, floating: true)
                .transition(AskMotion.panel(edge: .leading, reduceMotion: reduceMotion))
            } else {
                rightPanel
                    .frame(width: layout.drawerWidth)
                    .padding(.leading, style.usesGlass ? 8 : 0)
                    .transition(AskMotion.panel(edge: .trailing, reduceMotion: reduceMotion))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onExitCommand(perform: closeDrawer)
        .background {
            Button(L("ask.search"), action: openSearch).keyboardShortcut("k", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
    }

    private func closeDrawer() {
        presentation.closeDrawer(reduceMotion: reduceMotion) { model.authoringSession?.isPresented = false }
    }

    /// Native sidebar selection stays inside Ask's animated panel.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHistoryFilter {
                historyFilterPicker.padding(.horizontal, 10).padding(.vertical, 8)
            }
            historyList
            accountFooter
        }
    }

    private var workspaceTitle: String {
        model.selected?.title ?? model.conversations.first(where: { $0.id == model.selectedId })?.title ?? L("ask.new")
    }

    private var newConversationAction: TypefluxToolbarAction {
        .init(id: "ask.new", title: L("ask.new"), systemImage: "square.and.pencil",
              accessibilityIdentifier: "ask.workspace.new", shortcut: "n", perform: { model.newConversation() })
    }

    private var toolbarGroups: [TypefluxToolbarGroup] {
        var actions = [TypefluxToolbarAction(id: "ask.search", title: L("ask.search"), systemImage: "command",
                                             accessibilityIdentifier: "ask.workspace.search", shortcut: "k",
                                             perform: openSearch)]
        if let id = model.selectedId {
            actions.append(.init(id: "ask.usage", title: L("ask.usage.title"), systemImage: "chart.pie",
                                 accessibilityIdentifier: "ask.workspace.usage", perform: toggleUsage))
            actions.append(.init(id: "ask.delete", title: L("ask.delete"), systemImage: "trash", role: .destructive,
                                 perform: { deleteId = id }))
        }
        if layout.compactContent { actions = actions.filter { $0.id == "ask.usage" } }
        return [.init(id: "ask.actions", actions: actions)]
    }

    private var toolbarCenter: AnyView? {
        let local = model.storesLocally(launcher: false)
        let hasDetail = !layout.compactContent && ((!local && model.selected?.usage != nil) || model.runPhase != nil)
        guard layout.compactContent || !model.savedChatDrafts.isEmpty || (model.isSignedIn && local) || hasDetail
        else { return nil }
        return AnyView(toolbarStatus)
    }

    private var toolbarStatus: some View {
        HStack(spacing: 8) {
            if layout.compactContent { compactActions } else { savedDraftMenu }
            if model.isSignedIn, model.storesLocally(launcher: false) {
                Label(L("ask.storage.local"), systemImage: "lock")
                    .labelStyle(.iconOnly)
                    .font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .help(L("ask.storage.local.detail"))
            }
            if !layout.compactContent, !model.storesLocally(launcher: false), let usage = model.selected?.usage {
                Text(L("ask.usage.conversationSpent") + " " + usage.total.creditsText)
                    .font(.callout).monospacedDigit().lineLimit(1)
                    .help(L("ask.usage.conversationSpentHelp"))
            }
            if !layout.compactContent, let phase = model.runPhase {
                AskRunToneDot(tone: phase.tone)
                Text(phase.summary).font(.callout).lineLimit(1)
            }
        }
    }

    private var compactActions: some View {
        Menu {
            Button(L("ask.search"), action: openSearch).keyboardShortcut("k", modifiers: .command)
            if let id = model.selectedId {
                Button(L("ask.delete"), role: .destructive) { deleteId = id }
            }
            ForEach(model.savedChatDrafts) { saved in
                Button(saved.draft.title.isEmpty ? L("ask.drafts.untitled") : String(saved.draft.title.prefix(60))) {
                    Task { await model.restoreChatDraft(saved) }
                }
                .disabled(model.isOpeningChat)
            }
        } label: { Label(L("ask.search.actions"), systemImage: "ellipsis").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(L("ask.search.actions"))
            .accessibilityIdentifier("ask.workspace.more")
    }

    private var workspaceShortcuts: some View {
        newPrivateShortcut
            .background {
                // Keep this window's command registered while its visible button is hosted in the native toolbar.
                Button(L("ask.new"), action: { model.newConversation() })
                    .keyboardShortcut("n", modifiers: .command)
                    .hidden().accessibilityHidden(true)
            }
            .background {
                if layout.compactContent {
                    Button(L("ask.search"), action: openSearch).keyboardShortcut("k", modifiers: .command)
                        .hidden().accessibilityHidden(true)
                }
            }
    }

    private func toggleSidebar() {
        presentation.toggleSidebar(layout: layout, collapsed: sidebarCollapsed, reduceMotion: reduceMotion) {
            storedSidebarCollapsed = $0
        }
    }

    @ViewBuilder
    private var savedDraftMenu: some View {
        if !model.savedChatDrafts.isEmpty {
            Menu {
                ForEach(model.savedChatDrafts) { saved in
                    Button(saved.draft.title
                        .isEmpty ? L("ask.drafts.untitled") : String(saved.draft.title.prefix(60))) {
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

    /// ⇧⌘N without another visible control in the title bar.
    private var newPrivateShortcut: some View {
        Button(L("ask.storage.newLocal")) { model.newConversation(storesLocally: true) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.isSignedIn)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func openSearch() {
        presentation.openSearch(reduceMotion: reduceMotion) { model.authoringSession?.isPresented = false }
    }

    private func closeSearch() {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) { presentation.isSearching = false }
    }

    private var accountFooter: some View {
        SidebarAccountFooter(auth: auth, compact: layout.isShort,
                             defaults: model.modelLibrary.settings.defaults,
                             onSignIn: { LoginWindowController.shared.show() },
                             onOpenAccount: { model.onOpenSettings?(.account) },
                             onOpenSettings: { model.onOpenSettings?(.settings) }) {
            AskLocalModeIdentity(model: model, compact: false)
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
        case .usage: if !presentation.showsUsage { toggleUsage() }
        case .attachScreenshot:
            model.draft.includeScreenshot = true
            if model.draft.screenshot == nil { Task { await model.refreshScreenshot(launcher: false) } }
        }
    }

    /// The filter only appears once a conversation is kept on this Mac while signed in;
    /// signed out, every conversation is.
    private var showsHistoryFilter: Bool { model.isSignedIn && !model.localConversationIds.isEmpty }

    private var visibleConversations: [AskConversationSummary] {
        let items = showsHistoryFilter
            ? historyFilter.apply(model.conversations, isLocal: model.isLocal) : model.conversations
        return AskWorkspaceSearch.filter(items, query: toolbarSearch.query)
    }

    private var historySelection: Binding<String?> {
        Binding(get: { model.selectedId }, set: { id in
            guard let id, id != model.selectedId else { return }
            presentation.showsSidebarDrawer = false
            Task { await model.select(id) }
        })
    }

    private var historyFilterPicker: some View {
        AskHistoryFilterBar(selection: $historyFilter)
    }

    private var historyList: some View {
        let items = visibleConversations
        let sections = AskHistorySection.make(items, title: historyGroup)
        return List(selection: historySelection) {
            Group {
                ForEach(sections) { section in
                    Section {
                        if !collapsedGroups.contains(section.id) {
                            ForEach(section.items) { item in
                                historyRow(item).tag(item.id)
                                    .listRowInsets(EdgeInsets())
                            }
                        }
                    } header: {
                        groupHeader(section.id, first: section.id == sections.first?.id)
                            .textCase(nil)
                    }
                }
                if model.historyHasMore {
                    Button(L("ask.loadMore")) { Task { await model.refreshHistory(loadMore: true) } }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(TypefluxColor.accent.color)
                        .padding(.top, 8)
                }
                if items.isEmpty {
                    Text(L(toolbarSearch.query.isEmpty ? "ask.history.empty" : "ask.history.searchEmpty"))
                        .font(.subheadline)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .listRowSeparator(.hidden)
            .animation(AskMotion.panelAnimation(reduceMotion: reduceMotion), value: model.selectedId)
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("ask.workspace.history")
        .scrollContentBackground(.hidden)
        .background(AskHistoryPullRefresh(
            isRefreshing: model.isRefreshingHistory,
            onDistance: { pullDistance = $0 },
            onRefresh: { Task { await model.pullToRefreshHistory() } }
        ))
        .environment(\.defaultMinListRowHeight, style.ask.sidebarRowHeight)
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
                Image(systemName: "chevron.down").font(.footnote).fontWeight(.bold)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title).font(.subheadline).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
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
            .font(.subheadline)
            .foregroundStyle(failed && !refreshing ? TypefluxColor.warning.color : TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(TypefluxColor.controlBackground.color, in: Capsule())
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
            stored: model.isSignedIn && model.isLocal(item.id),
            selected: model.selectedId == item.id,
            busy: model.busyIds.contains(item.id),
            selectionSpace: selectionSpace,
            usesNativeSelection: true,
            onSelect: {
                presentation.showsSidebarDrawer = false
                Task { await model.select(item.id) }
            },
            onRename: { try await model.renameConversation(item.id, title: $0) },
            onDelete: { deleteId = item.id }
        )
    }

    private func historyGroup(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("ask.today") }
        if Calendar.current.isDateInYesterday(date) { return L("ask.yesterday") }
        return L("ask.earlier")
    }

    // MARK: - Content

    /// A solid reading column scrolls beneath the composer; the native toolbar owns the title.
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
            .mask(AskEdgeFade(topClear: 0,
                              bottomClear: layout.composerBottomInset,
                              fade: AskMetrics.transcriptEdgeFade,
                              topFade: 0))
            .overlay {
                if transcriptDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(TypefluxColor.accent.color, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(
                            TypefluxColor.accent.color.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
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
        }
        .onPreferenceChange(AskBottomChromeHeight.self) { bottomChromeHeight = $0 }
        .onChange(of: model.searchRequest) { _ in openSearch() }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The toolbar icon and the composer's context ring both toggle the panel:
    /// the same control that opened it closes it again.
    private func toggleUsage() {
        presentation.toggleUsage(runId: model.selected?.run?.id, reduceMotion: reduceMotion)
    }

    /// The usage panel slides in from the trailing edge like the sidebar.
    private func setUsage(_ shown: Bool) {
        presentation.setUsage(shown, reduceMotion: reduceMotion)
    }

    private var emptyState: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    if !layout.isShort {
                        AskEmptyStateOrb(voice: model.voiceInput).padding(.bottom, 20)
                    }
                    if !layout.isVeryShort {
                        Text(L("ask.empty")).font(layout.isShort ? .title : .largeTitle).bold()
                            .foregroundStyle(TypefluxColor.label.color)
                            .padding(.bottom, 9)
                    }
                    if !layout.isShort { emptyHint }
                    suggestions
                        .frame(maxWidth: AskMetrics.suggestionsMaxWidth)
                        .padding(.top, layout.isShort ? 4 : 26)
                    if hasStatus {
                        statusColumn
                            .frame(maxWidth: AskMetrics.suggestionsMaxWidth)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.vertical, layout.isShort ? 6 : 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, viewport.size.height - bottomChromeHeight))
            }
            .padding(.top, 8)
            .padding(.bottom, bottomChromeHeight)
        }
    }

    private var suggestions: some View {
        let arrangement = layout.compactContent
            ? AnyLayout(VStackLayout(spacing: layout.isVeryShort ? 4 : 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return arrangement {
            suggestion("ask.suggest.screen", systemImage: "display", tint: TypefluxColor.accent.color, shortcut: "1",
                       screenshot: true)
            suggestion("ask.suggest.selection", systemImage: "character.bubble", tint: TypefluxColor.accent.color,
                       shortcut: "2", screenshot: false)
            suggestion("ask.suggest.page", systemImage: "globe", tint: TypefluxColor.accent.color, shortcut: "3",
                       screenshot: false)
        }
    }

    /// Summon and voice shortcuts, read from the configured hotkeys.
    private var emptyHint: some View {
        AskShortcutHint(settings: model.modelLibrary.settings)
    }

    /// The caption used to sit at the trailing edge in the faintest grey in the
    /// window, where it read as a disabled tag. It belongs under its own title.
    /// This is a hotkey-summoned tool, so each row carries a real shortcut;
    /// Command-digit rather than Option-digit, which types a character.
    /// `key` names the title; its caption lives under `key + ".caption"`.
    /// The screenshot suggestion follows the model: it names the vision model a
    /// local draft moves to, or says why it cannot run and links to model settings.
    private func suggestion(_ key: String, systemImage: String, tint: Color,
                            shortcut: String, screenshot: Bool) -> some View {
        let title = L(key)
        let state = screenshot ? model.screenshotSuggestion(launcher: false) : .ready
        let caption = state.caption(default: L(key + ".caption"))
        let addsModel = state == .needsVisionModel
        return AskSuggestionCard(title: title, caption: caption, systemImage: systemImage, tint: tint,
                                 shortcut: shortcut, compact: layout.compactContent || layout.isShort,
                                 short: layout.isShort, dimmed: !state.enabled,
                                 captionAction: addsModel ? L("ask.vision.add") : nil) {
            if addsModel { model.onOpenSettings?(.models); return }
            model.draft.text = title
            if screenshot { model.attachScreenshotForSuggestion(launcher: false) }
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: .command)
        .accessibilityIdentifier("ask.workspace.suggestion." + key)
        .disabled(!state.enabled && !addsModel)
        .help((addsModel ? L("ask.vision.addHelp") : caption) + " · ⌘" + shortcut)
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
            || stoppedRun || resumable || model.hasRecoveryNotice || creditPaused
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
            .sheet(isPresented: $model.inspectingRecovery) { AskRecoveryInspector(model: model) }
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
            AskBanner(
                text: error,
                tone: .warning,
                actionTitle: model.selectionLoadFailed || !model.hasRecoveryNotice ? L("ask.retry") : nil,
                action: { if model.selectionLoadFailed { model.retrySelection() } else { model.resume() } },
                onDismiss: { model.error = nil }
            )
        }
        if let target = model.imageRecoveryTarget {
            AskImageRecoveryCard(model: model, target: target)
                .id(target.id)
        } else if stoppedRun, !model.hasRecoveryNotice, let value = model.selected,
                  !model.recoveryBlocksResume(value), let run = value.run {
            AskBanner(text: run.error ?? L("ask.cancelled"), tone: .info,
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
            AskComposer(model: model, compact: layout.isShort, availableWidth: layout.composerWidth,
                        availableHeight: layout.composerAvailableHeight,
                        launcher: false, onToggleUsage: { toggleUsage() })
                .disabled(model.isLoadingSelection)
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
            canAllowForConversation: model.canAllowForConversation(id),
            embedded: embedded,
            onDeny: { model.approve(conversationId: id, allowed: false, expectedApprovalID: approvalID) },
            onAllowForConversation: { model.approveForConversation(id, expectedApprovalID: approvalID) },
            onAllow: { model.approve(conversationId: id, allowed: true, expectedApprovalID: approvalID) }
        )
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
        let items = AskActivity.items(
            transcriptMessages,
            results: model.selected?.messages.filter { $0.role == "tool" } ?? []
        )
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
                                                           value: [item.id: geometry
                                                               .frame(in: .named("ask-transcript"))])
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
                                presentation.showsUsage = false
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
                .accessibilityIdentifier(restoredTranscript != nil && restoredTranscript == model.selectedId
                    ? "ask.workspace.transcript" : "ask.workspace.transcript.loading")
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
                        markerTop: bottom.minY, viewport: viewport.size.height, coveredBottom: bottomChromeHeight
                    ) {
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
    private func transcriptRow(_ item: AskTranscriptItem, items: [AskTranscriptItem],
                               regenerable: String?) -> some View {
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
                           onUsage: { presentation.usageRunId = message.runId; setUsage(true) },
                           isStreaming: message.id == streamingId,
                           canRegenerate: regenerable == message.id,
                           onRegenerate: { model.regenerate(message.id) },
                           outputs: item.outputs,
                           onSaveNote: model.notes == nil || message.role != "assistant" ? nil
                               : { excerpt in model.toggleAnswerNote(message, excerpt: excerpt) },
                           savedToNotes: model.answerNoteIDs[message.id] != nil)
        case let .activity(group):
            let results = model.selected?.messages.filter { $0.role == "tool" } ?? []
            let isLatest = items.last(where: { if case .activity = $0.kind { return true }; return false })?.id == group
                .id
            // The run's latest block stays live between steps, while no answer follows it yet,
            // and stops spinning with every other indicator once the run waits for a decision.
            let carriesRun = run?.isActive == true && items.last?.id == group.id
            let halted: Bool = {
                switch phase {
                case .needsDecision?, .pausedCredits?: break
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
            return AskMessage(
                id: item.id,
                role: "user",
                text: request.text,
                selection: request.selection,
                source: request.source,
                image: request.image,
                createdAt: Date(),
                references: request.references,
                steered: true,
                attachments: request.attachments,
                mcpServers: request.mcpServers
            )
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
                                      reasoning: progress.reasoning,
                                      reasoningMilliseconds: progress.reasoningMilliseconds))
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
    @Environment(\.interfaceStyle) private var style
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
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(TypefluxColor.label.color)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(TypefluxColor.controlBackground.color,
                                    in: AskBubbleShape(radius: TypefluxRadius.form.value(for: style), tail: 6))
                        .overlay(AskBubbleShape(radius: TypefluxRadius.form.value(for: style), tail: 6)
                            .strokeBorder(TypefluxColor.separator.color, lineWidth: 0.5))
                }
                AskMessageProvenanceView(message: message)
                if message.steered == true {
                    Label(
                        L(steeredPending ? "ask.steered.pending" : "ask.steered"),
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.subheadline)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
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
                AskTranscriptText(text: message.text, onAsk: isStreaming ? nil : { text, question in
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
            Circle().fill(TypefluxColor.warning.color).frame(width: 6, height: 6)
            Text(L("ask.answer.interrupted"))
                .font(.subheadline)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
            if canRegenerate, !isStreaming {
                Button(action: onRegenerate) {
                    Text(L("ask.regenerate"))
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(TypefluxColor.accent.color)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(TypefluxColor.accent.color.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canRegenerate && !isStreaming ? 3 : 10)
        .frame(height: 26)
        .background(TypefluxColor.label.color.opacity(0.06), in: Capsule())
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
                    Image(systemName: "sparkles").font(.subheadline)
                    Text(label)
                        .font(.callout).fontWeight(.medium)
                        .modifier(AskShimmer(active: active))
                    if !active {
                        Image(systemName: "chevron.right").font(.footnote).fontWeight(.bold)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(height: 26)
                .background(reasoningHover ? TypefluxColor.label.color.opacity(0.06) : Color.clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { reasoningHover = $0 }
            .padding(.leading, -8)
            .accessibilityLabel(label)
            if expanded {
                AskTranscriptText(text: text)
                    .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(TypefluxColor.separator.color).frame(width: 2) }
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

/// An empty-state suggestion: one of three content cards in a row. Hover lifts
/// it and fills its icon tile, so the starting points read as buttons.
private struct AskSuggestionCard: View {
    let title: String
    let caption: String
    let systemImage: String
    let tint: Color
    let shortcut: String
    var compact = false
    var short = false
    /// Shown as unavailable while still clickable, e.g. to open model settings.
    var dimmed = false
    /// A link after the caption, such as "Add".
    var captionAction: String?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceStyle) private var style
    private var available: Bool { isEnabled && !dimmed }

    static func corner(style: InterfaceStyle) -> CGFloat { style.ask.suggestionCorner }

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .foregroundStyle(available ? tint : TypefluxColor.tertiaryLabel.color)
                            .frame(width: 24, height: 24)
                            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.callout).fontWeight(.medium).lineLimit(1)
                            if !short {
                                Text(captionAction.map { caption + " · " + $0 } ?? caption)
                                    .font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, short ? 3 : 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        // The shortcut lives in the tooltip; the card face matches the design board.
                        let iconTint = available ? tint : TypefluxColor.tertiaryLabel.color
                        Image(systemName: systemImage).font(.body)
                            .foregroundStyle(hovering && available ? Color.white : iconTint)
                            .frame(width: 30, height: 30)
                            .background(hovering && available ? iconTint : iconTint.opacity(0.14),
                                        in: RoundedRectangle(
                                            cornerRadius: style.usesGlass ? 10 : 7,
                                            style: .continuous
                                        ))
                            .overlay(RoundedRectangle(cornerRadius: style.usesGlass ? 10 : 7, style: .continuous)
                                .strokeBorder(iconTint.opacity(0.35), lineWidth: 0.5))
                        Text(title).font(.body).fontWeight(.semibold)
                            .foregroundStyle(available ? TypefluxColor.label.color : TypefluxColor.tertiaryLabel.color)
                            .lineLimit(2, reservesSpace: true)
                            .fixedSize(horizontal: false, vertical: true)
                        (Text(caption).foregroundColor(TypefluxColor.tertiaryLabel.color)
                            + Text(captionAction.map { " · " + $0 } ?? "")
                            .fontWeight(.semibold).foregroundColor(TypefluxColor.accent.color))
                            .font(.subheadline).lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 13)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                }
            }
            .askContentCard(corner: Self.corner(style: style),
                            opaqueFill: style.usesGlass ? TypefluxColor.controlBackground.color
                                : (hovering && available ? AskClassic.cardHover : AskClassic.card),
                            elevatedInLight: false)
            .contentShape(RoundedRectangle(cornerRadius: Self.corner(style: style), style: .continuous))
            .opacity(available ? 1 : 0.7)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(AskLiftingCardStyle())
        .onHover { hovering = isEnabled && $0 }
        .accessibilityLabel(title)
        .accessibilityHint(caption)
    }
}

/// A file, image or folder sent with a question. Images and text open a preview;
/// a folder shows its location in Finder.
struct AskSentFileChip: View {
    let attachment: AskAttachment
    @State private var previewing = false

    var body: some View {
        Button {
            if attachment.kind == .folder, let path = attachment.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                previewing = true
            }
        } label: {
            AskSentAttachmentChip(
                title: [attachment.name, AskAttachmentStrip.caption(attachment)].compactMap { $0 }
                    .joined(separator: " · "),
                thumbnail: attachment.image.flatMap { AskAttachmentStrip.thumbnail(id: attachment.id, dataURL: $0) },
                systemImage: AskAttachmentStrip.symbol(attachment)
            )
            .frame(maxWidth: 260)
        }
        .buttonStyle(.plain)
        .help(attachment.path ?? attachment.name)
        .popover(isPresented: $previewing) { preview }
    }

    @ViewBuilder private var preview: some View {
        if let image = attachment.image.flatMap({ AskAttachmentStrip.thumbnail(id: attachment.id, dataURL: $0) }) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 650, maxHeight: 520).padding()
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
