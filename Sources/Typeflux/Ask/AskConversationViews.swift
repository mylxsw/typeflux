// swiftlint:disable file_length type_body_length
import AppKit
import SwiftUI

struct AskConversationView: View {
    @ObservedObject var model: AskConversationModel
    @State private var showsUsage = false
    @State private var usageRunId: String?
    @State private var deleteId: String?
    @State private var pullDistance: CGFloat = 0
    @State private var restoredTranscript: String?
    @State private var isSearching = false
    @State private var collapsedGroups: Set<String> = []
    @State private var searchHover = false
    /// The selected row's pill slides between rows instead of jumping.
    @Namespace private var selectionSpace
    /// Height of the banners and composer floating over the transcript's bottom edge.
    @State private var bottomChromeHeight: CGFloat = 0
    /// Set by the toggle inside its animation. Driving the layout from the
    /// `@AppStorage` value alone re-rendered outside the animation, so the
    /// sidebar popped in and out instead of sliding.
    @State private var sidebarChoice: Bool?
    @AppStorage("ask.sidebarCollapsed") private var storedSidebarCollapsed = false
    @AppStorage(AskCloudPromo.dismissedKey) private var cloudPromoDismissedAt: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowWidth: CGFloat = 0
    @ObservedObject private var auth: AuthState

    init(model: AskConversationModel, showsUsage: Bool = false, auth: AuthState = .shared) {
        self.model = model
        self.auth = auth
        _showsUsage = State(initialValue: showsUsage)
        _usageRunId = State(initialValue: model.selected?.run?.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !sidebarHidden {
                    sidebar.frame(width: AskMetrics.sidebarWidth)
                        .transition(AskMotion.panel(edge: .leading, reduceMotion: reduceMotion))
                }
                content
                if showsUsage {
                    AskUsagePanel(model: model, runId: $usageRunId, close: { setUsage(false) })
                        .id(model.selectedId)
                        .transition(AskMotion.panel(edge: .trailing, reduceMotion: reduceMotion))
                }
            }
            // One surface for the whole window: the sidebar floats on it as a
            // glass panel instead of being a differently tinted column.
            .background(AskWindowBackdrop())
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AskWindowWidth.self, value: geometry.size.width)
            })
            titleBarTools
            if isSearching { searchPalette }
        }
        // Lay out from the very top of the window so the tools share the
        // traffic lights' baseline instead of sitting below the title bar.
        .onChange(of: model.selectedId) { _ in usageRunId = nil }
        .onPreferenceChange(AskWindowWidth.self) { width in
            withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) { windowWidth = width }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 740, minHeight: 530)
        .tint(AskTheme.accent)
        .onChange(of: model.draft) { _ in model.persistDrafts() }
        .confirmationDialog(
            L("ask.delete.confirm"),
            isPresented: Binding(get: { deleteId != nil }, set: { if !$0 { deleteId = nil } })
        ) {
            Button(L("ask.delete"), role: .destructive) {
                if let id = deleteId { Task { await model.delete(id) } }
                deleteId = nil
            }
        }
    }

    // MARK: - Sidebar

    /// The user's choice: this window's latest toggle, else the stored preference.
    private var sidebarCollapsed: Bool { sidebarChoice ?? storedSidebarCollapsed }

    /// Hidden by the user, or stepping aside while the usage panel needs the
    /// room: three columns overflowed a narrow window and pushed the sidebar
    /// against its edge.
    private var sidebarHidden: Bool {
        sidebarCollapsed || AskPresentation.sidebarYields(windowWidth: windowWidth, usageShown: showsUsage)
    }

    /// A glass panel floating inset from the window edges, with the traffic
    /// lights inside its top strip, instead of a full-height column split off by a rule.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window uses a full-size content view; this strip clears the
            // traffic lights. The compose and toggle buttons float above it.
            Color.clear.frame(height: AskMetrics.sidebarTopInset - AskMetrics.sidebarPanelInset)
            sidebarSearchField.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
            historyList
            accountFooter
        }
        .askInWindowGlass(corner: AskMetrics.sidebarPanelCorner, opaqueFill: AskTheme.glassFill)
        .padding([.leading, .top, .bottom], AskMetrics.sidebarPanelInset)
    }

    /// New chat and the sidebar toggle live in the title bar row, like Notes and
    /// Mail. Expanded, they are right-aligned inside the sidebar; collapsed, they
    /// follow the traffic lights in one pill with search, so "new chat" never moves
    /// out of reach.
    private var titleBarTools: some View {
        HStack(spacing: 2) {
            if !sidebarHidden { Spacer(minLength: 0) }
            if sidebarHidden {
                // Without the panel behind them the tools float like the header's pills.
                collapsedTools
                    .padding(.horizontal, 3)
                    .frame(height: AskMetrics.headerCapsuleHeight)
                    .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            } else {
                composeButton
                sidebarToggle
            }
        }
        .padding(.leading, sidebarHidden ? AskMetrics.trafficLightInset : 0)
        .padding(.trailing, sidebarHidden ? 0 : 6 + AskMetrics.sidebarPanelInset)
        .frame(width: sidebarHidden ? nil : AskMetrics.sidebarWidth, alignment: .leading)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private var sidebarToggle: some View {
        titleBarButton("sidebar.left", label: L("ask.sidebar.toggle"), shortcut: "⌃⌘S") { toggleSidebar() }
            .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private func toggleSidebar() {
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) {
            // A sidebar that stepped aside for the usage panel comes back by closing the panel.
            if !sidebarCollapsed, sidebarHidden {
                showsUsage = false
            } else {
                sidebarChoice = !sidebarCollapsed
                storedSidebarCollapsed = sidebarChoice ?? false
            }
        }
    }

    /// Expanded, the sidebar owns the search entry; collapsed, it moves here.
    private var collapsedTools: some View {
        HStack(spacing: 0) {
            sidebarToggle
            titleBarButton("magnifyingglass", label: L("ask.search")) { openSearch() }
                .keyboardShortcut("k", modifiers: .command)
            composeButton
        }
    }

    /// The window's one "new chat" entry: a compose icon instead of a coloured
    /// row competing with the history list.
    private var composeButton: some View {
        titleBarButton("square.and.pencil", label: L("ask.new"), shortcut: "⌘N") { model.newConversation() }
            .keyboardShortcut("n", modifiers: .command)
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
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(searchHover ? AskTheme.pressFill : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AskTheme.separator, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { searchHover = $0 }
        .keyboardShortcut("k", modifiers: .command)
        .help(L("ask.search"))
        .accessibilityLabel(L("ask.search"))
    }

    private func openSearch() {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) { isSearching = true }
    }

    private func closeSearch() {
        withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) { isSearching = false }
    }

    /// The name and plan badge (hover or click for the account card), or a
    /// sign-in link; the letter badge that used to lead it pointed at nothing.
    private var accountFooter: some View {
        VStack(spacing: 0) {
            if !auth.isLoggedIn, AskCloudPromo.isVisible(dismissedAt: cloudPromoDismissedAt) {
                AskCloudPromoCard(onSignIn: { LoginWindowController.shared.show() }, onDismiss: {
                    withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) {
                        cloudPromoDismissedAt = Date().timeIntervalSince1970
                    }
                })
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
            Rectangle().fill(AskTheme.separator).frame(height: 0.5)
            accountFooterRow
        }
    }

    /// Signed out, the footer says where Ask runs; the Cloud card above it carries the sign-in.
    @ViewBuilder private var footerIdentity: some View {
        if auth.isLoggedIn {
            AskAccountFooterIdentity(auth: auth, name: accountName, runsLocally: !model.cloudAvailable) {
                model.onOpenSettings?(.account)
            }
        } else {
            AskLocalModeIdentity(model: model)
        }
    }

    private var accountFooterRow: some View {
        HStack(spacing: 9) {
            footerIdentity
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button { model.onOpenSettings?(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(AskPressableStyle())
            .help(L("sidebar.settingsAccessibility"))
            .accessibilityLabel(L("sidebar.settingsAccessibility"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: auth.isLoggedIn ? 52 : 56)
    }

    private var accountName: String {
        AskPresentation.accountName(name: auth.userProfile?.name, email: auth.userProfile?.email)
            ?? L("sidebar.appName")
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
            default:
                return true
            }
        }
    }

    private func runPaletteAction(_ action: AskPaletteAction) {
        switch action {
        case .newConversation: model.newConversation()
        case .toggleSidebar: toggleSidebar()
        case .usage: if !showsUsage { toggleUsage() }
        case .attachScreenshot:
            model.draft.includeScreenshot = true
            if model.draft.screenshot == nil { Task { await model.refreshScreenshot(launcher: false) } }
        }
    }

    private var visibleConversations: [AskConversationSummary] {
        model.conversations
    }

    private var historyList: some View {
        let items = visibleConversations
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index == 0 || historyGroup(items[index - 1].updatedAt) != historyGroup(item.updatedAt) {
                        groupHeader(historyGroup(item.updatedAt), first: index == 0)
                    }
                    if !collapsedGroups.contains(historyGroup(item.updatedAt)) {
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
                if items.isEmpty {
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
            selectionSpace: selectionSpace,
            onSelect: { Task { await model.select(item.id) } },
            onDelete: { deleteId = item.id }
        )
    }

    private func historyGroup(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("ask.today") }
        if Calendar.current.isDateInYesterday(date) { return L("ask.yesterday") }
        return L("ask.earlier")
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
            .mask(AskEdgeFade(topClear: AskMetrics.headerCapsuleTop, bottomClear: AskMetrics.composerBottomInset,
                              fade: AskMetrics.transcriptEdgeFade))
            VStack(spacing: 0) {
                statusColumn
                composerArea
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AskBottomChromeHeight.self, value: geometry.size.height)
            })
            .frame(maxHeight: .infinity, alignment: .bottom)
            header
        }
        .onPreferenceChange(AskBottomChromeHeight.self) { bottomChromeHeight = $0 }
        .frame(minWidth: AskMetrics.contentMinWidth)
    }

    /// The title and the conversation's actions as two glass capsules over the
    /// transcript: the title carries the run's state as a dot and a summary;
    /// the actions capsule carries the credits spent, usage, a new chat and delete.
    private var header: some View {
        HStack(spacing: 8) {
            if let id = model.selectedId {
                HStack(spacing: 10) {
                    Text(model.selected?.title
                         ?? model.conversations.first(where: { $0.id == model.selectedId })?.title
                         ?? L("ask.new"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    if model.isLoadingSelection, model.selected != nil { ProgressView().controlSize(.small) }
                    if let summary = AskActivity.runSummary(model.selected?.run,
                                                            pendingApproval: model.pendingApprovals[id] != nil) {
                        HStack(spacing: 5) {
                            if let tone = AskRunTone.of(model.selected?.run,
                                                        pendingApproval: model.pendingApprovals[id] != nil) {
                                AskRunToneDot(tone: tone)
                            }
                            Text(summary)
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .frame(height: AskMetrics.headerCapsuleHeight)
                .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            } else {
                Text(L("ask.new"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: AskMetrics.headerCapsuleHeight)
                    .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if let credits = headerCredits {
                    Button { toggleUsage() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AskTheme.accent)
                            (Text(credits).font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(StudioTheme.textPrimary)
                                + Text(verbatim: " credits").font(.system(size: 12.5))
                                .foregroundColor(StudioTheme.textSecondary))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(showsUsage ? AskTheme.hoverFill : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L("ask.usage.title"))
                    .accessibilityLabel(L("ask.usage.title"))
                    .accessibilityValue(credits + " credits")
                    Rectangle().fill(AskTheme.separator).frame(width: 1, height: 18).padding(.horizontal, 4)
                } else if model.selectedId != nil {
                    headerAction(.usage, label: L("ask.usage.title"), active: showsUsage) { toggleUsage() }
                }
                AskHeaderIconButton(symbol: "square.and.pencil", label: L("ask.new"), shortcut: "⌘N") {
                    model.newConversation()
                }
                if let id = model.selectedId {
                    headerAction(.trash, label: L("ask.delete")) { deleteId = id }
                }
            }
            .padding(.horizontal, 3)
            .frame(height: AskMetrics.headerCapsuleHeight)
            .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
        }
        .padding(.leading, sidebarHidden ? AskMetrics.collapsedTitleInset : 14)
        .padding(.trailing, 14)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private var headerCredits: String? {
        guard model.selectedId != nil, let usage = model.selected?.usage else { return nil }
        return usage.total.creditsText
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
        withAnimation(AskMotion.panelAnimation(reduceMotion: reduceMotion)) { showsUsage = shown }
    }

    private func headerAction(_ kind: AskLineGlyph.Kind, label: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        AskHeaderLineButton(kind: kind, label: label, active: active, action: action)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            AskEmptyStateOrb(voice: model.voiceInput).padding(.bottom, 20)
            Text(L("ask.empty")).font(.system(size: 26, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.bottom, 9)
            emptyHint
            HStack(alignment: .top, spacing: 12) {
                suggestion("ask.suggest.screen", systemImage: "display", tint: AskTheme.accent, shortcut: "1",
                           screenshot: true)
                suggestion("ask.suggest.selection", systemImage: "character.bubble", tint: AskTheme.accent,
                           shortcut: "2", screenshot: false)
                suggestion("ask.suggest.page", systemImage: "globe", tint: AskTheme.accent, shortcut: "3",
                           screenshot: false)
            }
            .frame(maxWidth: AskMetrics.suggestionsMaxWidth)
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, AskMetrics.titleBarRowHeight)
        .padding(.bottom, bottomChromeHeight)
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
                                 shortcut: shortcut, dimmed: !state.enabled,
                                 captionAction: addsModel ? L("ask.vision.add") : nil) {
            if addsModel { model.onOpenSettings?(.models); return }
            model.draft.text = title
            if screenshot { model.attachScreenshotForSuggestion(launcher: false) }
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: .command)
        .disabled(!state.enabled && !addsModel)
        .help((addsModel ? L("ask.vision.addHelp") : caption) + " · ⌘" + shortcut)
    }

    /// Banners and cards above the composer share its centred column, so they
    /// line up with the input instead of spanning the whole window.
    private var statusColumn: some View {
        VStack(spacing: 6) { statusArea }
            .frame(maxWidth: AskMetrics.composerMaxWidth)
            .padding(.horizontal, 22)
    }

    @ViewBuilder private var statusArea: some View {
        if let change = model.visibleVisionSwitch {
            AskBanner(text: String(format: L("ask.vision.switched"), model.modelLibrary.name(for: change.to)),
                      tone: .info, systemImage: "eye",
                      actionTitle: String(format: L("ask.vision.revert"), model.modelLibrary.name(for: change.from)),
                      action: { model.revertVisionSwitch() },
                      onDismiss: { model.visionSwitch = nil })
        }
        if model.imageRecoveryTarget == nil, let error = model.error {
            AskBanner(
                text: error,
                tone: .warning,
                actionTitle: L("ask.retry"),
                action: { if model.selectionLoadFailed { model.retrySelection() } else { model.resume() } },
                onDismiss: { model.error = nil }
            )
        }
        if let target = model.imageRecoveryTarget {
            AskImageRecoveryCard(model: model, target: target)
                .id(target.id)
        } else if !model.hasPendingSubmission, let run = model.selected?.run, run.status == "failed" || run.status == "cancelled", !model.isBusy {
            AskBanner(text: run.error ?? L("ask.cancelled"), tone: .info,
                      systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
        } else if resumable, model.error == nil {
            AskBanner(text: L("ask.resume.hint"), tone: .info, systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
        }
    }

    /// An interrupted run: either the request never started, or it is still
    /// active on this conversation while no local operation is driving it.
    private var resumable: Bool {
        guard let selected = model.selected, !model.isBusy else { return false }
        if model.hasPendingSubmission { return true }
        if selected.run == nil, selected.messages.last?.role == "user" { return true }
        return selected.run?.isActive == true && !model.busyIds.contains(selected.id)
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            // Stop lives in the send button's place while the run works.
            // The context budget used to occupy a whole row of its own below the
            // composer; it now rides in the footer next to the send button.
            AskComposer(model: model, launcher: false, onToggleUsage: { toggleUsage() })
                .disabled(model.isLoadingSelection)
            AskComposerHint(voice: model.voiceInput, contextID: "chat:" + (model.selectedId ?? "new"),
                            settings: model.modelLibrary.settings)
        }
        .frame(maxWidth: AskMetrics.composerMaxWidth)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, AskMetrics.composerBottomInset)
    }

    /// The decision sits at the end of the conversation it belongs to.
    private func approval(_ call: AskToolCall, id: String) -> some View {
        approvalCard(call, id: id, embedded: false)
            .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
    }

    private func approvalCard(_ call: AskToolCall, id: String, embedded: Bool) -> AskApprovalCard {
        AskApprovalCard(call: call, risk: model.approvalRisk(id) ?? .destructive,
                        mcpServer: model.mcpServerName(of: call),
                        canAllowForConversation: model.canAllowForConversation(id),
                        embedded: embedded,
                        onDeny: { model.approve(conversationId: id, allowed: false) },
                        onAllowForConversation: { model.approveForConversation(id) },
                        onAllow: { model.approve(conversationId: id, allowed: true) })
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
                        // A decision for a step in a tool card sits inside that card.
                        if let id = model.selected?.id, let call = model.pendingApprovals[id],
                           !Self.groupContains(items, callId: call.id) {
                            approval(call, id: id).id("approval-" + call.id)
                        }
                        // Jumped messages wait after everything the run still has to finish.
                        ForEach(steeredMessages) { message in
                            AskMessageView(message: message, steeredPending: true, onReference: { _ in }).id(message.id)
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
                    .padding(.horizontal, AskMetrics.columnInset)
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
                }
                .onPreferenceChange(AskTranscriptFrames.self) { frames in
                    guard let id = model.selectedId, restoredTranscript == id else { return }
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
                .onChange(of: model.selected?.run?.preview) { _ in followBottom(proxy) }
                .onChange(of: model.inferenceProgress) { _ in followBottom(proxy) }
                .onChange(of: model.selected?.messages.count) { _ in followBottom(proxy) }
                .onChange(of: model.selectedId.flatMap { model.pendingApprovals[$0]?.id }) { _ in followBottom(proxy) }
                .onChange(of: model.steeredMessages.count) { _ in followBottom(proxy) }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: AskTranscriptItem, items: [AskTranscriptItem], regenerable: String?) -> some View {
        let run = model.selected?.run
        let streamingId = run?.isActive == true ? run?.assistantId : nil
        let approvalToolId = model.selectedId.flatMap { model.pendingApprovals[$0]?.id }
        switch item.kind {
        case let .message(message):
            AskMessageView(message: message,
                           onReference: { model.addReference($0) },
                           onLocate: { model.referenceLocation = $0 },
                           usage: message.runId.flatMap { model.selected?.usage?.runs[$0] },
                           onUsage: { usageRunId = message.runId; setUsage(true) },
                           isStreaming: message.id == streamingId,
                           canRegenerate: regenerable == message.id,
                           onRegenerate: { model.regenerate(message.id) },
                           outputs: item.outputs)
        case let .activity(group):
            let results = model.selected?.messages.filter { $0.role == "tool" } ?? []
            let isLatest = items.last(where: { if case .activity = $0.kind { return true }; return false })?.id == group.id
            // The run's latest block stays live between steps, while no answer follows it yet.
            let live = run?.isActive == true && items.last?.id == group.id
            let status = AskActivity.status(group, results: results, streamingId: streamingId,
                                            approvalToolId: approvalToolId, live: live)
            let pending = model.selectedId.flatMap { id in
                model.pendingApprovals[id].map { (id: id, call: $0) }
            }
            AskActivityBlock(group: group, results: results,
                             plan: AskActivity.plan(for: group, run: run, isLatest: isLatest),
                             status: status, streamingId: streamingId, approvalToolId: approvalToolId,
                             outputs: item.outputs,
                             approval: pending.flatMap { pending in
                                 group.calls.contains { $0.id == pending.call.id }
                                     ? AnyView(approvalCard(pending.call, id: pending.id, embedded: true)) : nil
                             })
                .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
        }
    }

    /// Jumped messages the run has not read yet, as user turns.
    private var steeredMessages: [AskMessage] {
        model.steeredMessages.map { item in
            let request = item.draft.request(deviceId: model.deviceId, tools: [], id: item.id)
            return AskMessage(id: item.id, role: "user", text: request.text, selection: request.selection, source: request.source,
                              image: request.image, createdAt: Date(), references: request.references, steered: true)
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

    private func followBottom(_ proxy: ScrollViewProxy) {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? AskTranscriptText.Editor,
           editor.selectedRange().length > 0 { return }
        guard let id = model.selectedId, restoredTranscript == id,
              model.transcriptPositions[id] == "bottom" else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func restoreTranscript(_ proxy: ScrollViewProxy) {
        guard let id = model.selected?.id, restoredTranscript != id else { return }
        let anchor = model.transcriptPositions[id] ?? "bottom"
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
    @State private var showImage = false
    @State private var showSelection = false
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
                // What rode with the question sits above it, as on the design board.
                if message.image != nil || message.selection != nil { attachments }
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
                        .background(AskTheme.accent.opacity(0.18), in: AskBubbleShape(radius: 20, tail: 6))
                        .overlay(AskBubbleShape(radius: 20, tail: 6)
                            .strokeBorder(AskTheme.accent.opacity(0.42), lineWidth: 0.5))
                }
                if message.steered == true {
                    Label(L(steeredPending ? "ask.steered.pending" : "ask.steered"), systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .frame(maxWidth: AskMetrics.bubbleMaxWidth, alignment: .trailing)
        }
    }

    private var attachments: some View {
        HStack(spacing: 6) {
            if let text = message.selection {
                Button { showSelection = true } label: {
                    AskSentAttachmentChip(title: L("ask.selection.lines", AskPresentation.lineCount(text)),
                                          systemImage: "text.alignleft")
                }
                .buttonStyle(.plain)
                    .popover(isPresented: $showSelection) {
                        ScrollView {
                            Text(text).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 380, height: 220)
                        .padding(14)
                    }
            }
            if let url = message.image, let image = AskImage.decode(url) {
                Button { showImage.toggle() } label: {
                    AskSentAttachmentChip(title: L("ask.context.screenshot.attached"), thumbnail: image)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.preview"))
                .popover(isPresented: $showImage) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 650).padding()
                }
            }
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
                })
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
            // The answer's cost is a quiet caption that opens the usage panel.
            Button(action: onUsage) {
                Text(usageLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("ask.usage.title"))
            .accessibilityLabel(L("ask.usage.title"))
            .accessibilityValue(usageLabel)
        }
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var usageLabel: String {
        guard let usage else { return L("ask.usage.title") }
        return usage.creditsText + " credits"
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
                    Image(systemName: "sparkles").font(.system(size: 11))
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
                AskTranscriptText(text: text)
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

/// A history row. Hovering swaps the timestamp for an overflow menu, so the row
/// actions are discoverable without a right click.
private struct AskHistoryRow: View {
    let title: String
    let updatedAt: Date
    let selected: Bool
    let busy: Bool
    let selectionSpace: Namespace.ID
    var onSelect: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // A conversation still working shows a breathing accent dot.
                if busy { AskRunToneDot(tone: .running) }
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !busy {
                    Text(AskPresentation.historyTimeLabel(updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .monospacedDigit()
                        .opacity(hovering ? 0 : 1)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selection is an accent-tinted glass pill, concentric with the panel,
            // that slides from the previous row to the new one.
            .background {
                let shape = RoundedRectangle(cornerRadius: AskMetrics.sidebarRowCorner, style: .continuous)
                ZStack {
                    if hovering, !selected { shape.fill(AskTheme.hoverFill).transition(.opacity) }
                    if selected {
                        shape.fill(AskTheme.accent.opacity(0.18))
                            .overlay(shape.strokeBorder(AskTheme.accent.opacity(0.4), lineWidth: 0.5))
                            .shadow(color: AskTheme.accent.opacity(0.18), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "ask.history.selection", in: selectionSpace)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: AskMetrics.sidebarRowCorner, style: .continuous))
        }
        .buttonStyle(AskPressableStyle.subtle)
        // Always mounted and only faded: removing the menu on hover-out would
        // tear it down while its popup is still tracking the pointer.
        .overlay(alignment: .trailing) {
            Menu {
                Button(L("ask.delete"), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.trailing, 10)
            .opacity(hovering && !busy ? 1 : 0)
            .allowsHitTesting(hovering && !busy)
            .accessibilityHidden(busy)
            .help(L("ask.delete"))
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L("ask.delete"), role: .destructive, action: onDelete).disabled(busy)
        }
    }

}

/// An empty-state suggestion: one of three glass cards in a row. Hover lifts
/// it and fills its icon tile, so the starting points read as buttons.
private struct AskSuggestionCard: View {
    let title: String
    let caption: String
    let systemImage: String
    let tint: Color
    let shortcut: String
    /// Shown as unavailable while still clickable, e.g. to open model settings.
    var dimmed = false
    /// A link after the caption, such as "Add".
    var captionAction: String?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    private var available: Bool { isEnabled && !dimmed }

    static var corner: CGFloat { 18 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                // The shortcut lives in the tooltip; the card face matches the design board.
                let iconTint = available ? tint : StudioTheme.textTertiary
                Image(systemName: systemImage).font(.system(size: 14))
                    .foregroundStyle(hovering && available ? Color.white : iconTint)
                    .frame(width: 30, height: 30)
                    .background(hovering && available ? iconTint : iconTint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(iconTint.opacity(0.35), lineWidth: 0.5))
                Text(title).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(available ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                (Text(caption).foregroundColor(StudioTheme.textTertiary)
                    + Text(captionAction.map { " · " + $0 } ?? "").fontWeight(.semibold).foregroundColor(AskTheme.accentText))
                    .font(.system(size: 11.5)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 13)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .askInWindowGlass(corner: Self.corner, opaqueFill: AskTheme.composerSurface)
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .opacity(available ? 1 : 0.7)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(AskLiftingCardStyle())
        .onHover { hovering = isEnabled && $0 }
        .accessibilityLabel(title)
        .accessibilityHint(caption)
    }
}
