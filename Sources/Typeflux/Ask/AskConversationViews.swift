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
    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var collapsedGroups: Set<String> = []
    @State private var headerHovering = false
    /// Height of the banners and composer floating over the transcript's bottom edge.
    @State private var bottomChromeHeight: CGFloat = 0
    /// Set by the toggle inside its animation. Driving the layout from the
    /// `@AppStorage` value alone re-rendered outside the animation, so the
    /// sidebar popped in and out instead of sliding.
    @State private var sidebarChoice: Bool?
    @AppStorage("ask.sidebarCollapsed") private var storedSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowWidth: CGFloat = 0
    @ObservedObject private var auth = AuthState.shared

    init(model: AskConversationModel, showsUsage: Bool = false) {
        self.model = model
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
        .background(StudioGlassBackground(tintOpacity: StudioTheme.Opacity.glassBackgroundTint))
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
            sidebarSearchField.padding(.horizontal, 8).padding(.bottom, 10)
            historyList
            accountFooter
        }
        .askInWindowGlass(corner: AskMetrics.sidebarPanelCorner, opaqueFill: AskTheme.sidebarSurface)
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
        titleBarButton("sidebar.left", label: L("ask.sidebar.toggle")) {
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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text(L("ask.search")).font(.system(size: 12.5))
                Spacer(minLength: 4)
                Text(verbatim: "⌘K").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(AskTheme.hoverFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help(L("ask.search"))
        .accessibilityLabel(L("ask.search"))
    }

    private func openSearch() {
        query = ""
        isSearching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        isSearching = false
        query = ""
    }

    private var accountFooter: some View {
        HStack(spacing: 9) {
            AskAccountBadge(name: accountName)
            Text(accountName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { model.onOpenSettings?(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("sidebar.settingsAccessibility"))
            .accessibilityLabel(L("sidebar.settingsAccessibility"))
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private var accountName: String {
        AskPresentation.accountName(name: auth.userProfile?.name, email: auth.userProfile?.email)
            ?? L("sidebar.appName")
    }

    // MARK: - Search palette

    /// Centered search card over a dimmed window: a field with a close button,
    /// an action row and the matching conversations. Esc or a click outside closes it.
    private var searchPalette: some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { closeSearch() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14))
                        .foregroundStyle(StudioTheme.textTertiary)
                    TextField(L("ask.search"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .focused($searchFocused)
                        .onSubmit { openFirstSearchResult() }
                    Button { closeSearch() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(AskTheme.controlSurface, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("ask.remove"))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            paletteHeader(L("ask.search.actions"))
                            paletteRow(title: L("ask.new"), systemImage: "square.and.pencil", time: nil) {
                                closeSearch(); model.newConversation()
                            }
                        }
                        paletteHeader(L("ask.search.conversations"))
                        let results = AskPresentation.filterHistory(model.conversations, query: query)
                        ForEach(results, id: \.id) { item in
                            paletteRow(title: item.title, systemImage: "bubble.left", time: item.updatedAt) {
                                closeSearch(); Task { await model.select(item.id) }
                            }
                        }
                        if results.isEmpty {
                            Text(L(query.isEmpty ? "ask.history.empty" : "ask.history.searchEmpty"))
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 560, height: 420)
            .askInWindowGlass(corner: AskMetrics.paletteCorner)
            .shadow(color: Color.black.opacity(0.35), radius: 24, y: 10)
        }
        .onExitCommand { closeSearch() }
        .transition(.opacity)
    }

    private func paletteHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func paletteRow(title: String, systemImage: String, time: Date?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let time {
                    Text(time, style: .time).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Return opens the top match, or starts a new chat when nothing is typed.
    private func openFirstSearchResult() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            closeSearch(); model.newConversation(); return
        }
        guard let first = AskPresentation.filterHistory(model.conversations, query: query).first else { return }
        closeSearch()
        Task { await model.select(first.id) }
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
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, first ? 2 : 12)
            .padding(.bottom, 4)
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
    /// transcript. The actions stay dimmed until the pointer is over them, so
    /// the delete button never carries the same weight as the title.
    private var header: some View {
        HStack(spacing: 8) {
            if model.selectedId != nil {
                HStack(spacing: 8) {
                    Text(model.selected?.title
                         ?? model.conversations.first(where: { $0.id == model.selectedId })?.title
                         ?? L("ask.new"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    if model.isLoadingSelection, model.selected != nil { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14)
                .frame(height: AskMetrics.headerCapsuleHeight)
                .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
            }
            Spacer(minLength: 8)
            if let id = model.selectedId {
                HStack(spacing: 2) {
                    if let credits = headerCredits {
                        Text(credits)
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.leading, 10)
                            .padding(.trailing, 4)
                    }
                    headerAction(.usage, label: L("ask.usage.title"), active: showsUsage) { toggleUsage() }
                    headerAction(.trash, label: L("ask.delete")) { deleteId = id }
                }
                // Only the actions recede; the pill itself stays as solid as the title's.
                .opacity(headerHovering || showsUsage ? 1 : 0.55)
                .animation(.easeOut(duration: 0.15), value: headerHovering)
                .padding(.horizontal, 3)
                .frame(height: AskMetrics.headerCapsuleHeight)
                .askInWindowGlassPill(height: AskMetrics.headerCapsuleHeight)
                .onHover { headerHovering = $0 }
            }
        }
        .padding(.leading, sidebarHidden ? AskMetrics.collapsedTitleInset : 14)
        .padding(.trailing, 14)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private var headerCredits: String? {
        guard model.selectedId != nil, let usage = model.selected?.usage else { return nil }
        return usage.total.creditsText + " credits"
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
        Button(action: action) {
            AskLineIcon(kind: kind, size: 15)
                .foregroundStyle(active ? AskTheme.accent : StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(active ? AskTheme.hoverFill : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            AskBrandMark().padding(.bottom, 18)
            Text(L("ask.empty")).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.bottom, 7)
            emptyHint
            HStack(alignment: .top, spacing: 12) {
                suggestion("ask.suggest.screen", systemImage: "display", tint: .blue, shortcut: "1", screenshot: true)
                suggestion("ask.suggest.selection", systemImage: "text.cursor", tint: .purple, shortcut: "2",
                           screenshot: false)
                suggestion("ask.suggest.page", systemImage: "globe", tint: .green, shortcut: "3", screenshot: false)
            }
            .frame(maxWidth: AskMetrics.composerMaxWidth)
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
    private func suggestion(_ key: String, systemImage: String, tint: Color,
                            shortcut: String, screenshot: Bool) -> some View {
        let title = L(key), caption = L(key + ".caption")
        return AskSuggestionCard(title: title, caption: caption, systemImage: systemImage, tint: tint,
                                 shortcut: shortcut) {
            model.draft.text = title
            if screenshot { model.draft.includeScreenshot = true }
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: .command)
        .disabled(screenshot && model.screenshotCapability(launcher: false) != .supported)
        .help(screenshot ? (model.screenshotCapability(launcher: false).hint ?? caption) : caption)
    }

    /// Banners and cards above the composer share its centred column, so they
    /// line up with the input instead of spanning the whole window.
    private var statusColumn: some View {
        VStack(spacing: 6) { statusArea }
            .frame(maxWidth: AskMetrics.composerMaxWidth)
            .padding(.horizontal, 22)
    }

    @ViewBuilder private var statusArea: some View {
        if model.imageRecoveryTarget == nil, let error = model.error {
            AskBanner(
                text: error,
                tone: .warning,
                actionTitle: L("ask.retry"),
                action: { if model.selectionLoadFailed { model.retrySelection() } else { model.resume() } },
                onDismiss: { model.error = nil }
            )
        }
        if let id = model.selected?.id, let call = model.pendingApprovals[id] {
            approval(call, id: id)
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
            if model.isBusy {
                Button { model.stop() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text(L("ask.stop")).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .askInWindowGlassPill(height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.stop"))
            }
            // The context budget used to occupy a whole row of its own below the
            // composer; it now rides in the footer next to the send button.
            AskComposer(model: model, launcher: false, onToggleUsage: { toggleUsage() })
                .disabled(model.isLoadingSelection)
        }
        .frame(maxWidth: AskMetrics.composerMaxWidth)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, AskMetrics.composerBottomInset)
    }

    private func approval(_ call: AskToolCall, id: String) -> some View {
        AskToolCard(
            title: AskTheme.toolTitle(call),
            subtitle: model.selected?.messages.first(where: { $0.role == "user" })?.source,
            systemImage: AskPresentation.toolSymbol(call),
            state: .attention,
            statusText: L("ask.tool.pending"),
            startsExpanded: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                AskMonoBlock(title: L("ask.tool.arguments"), text: call.function.arguments)
                HStack(spacing: 8) {
                    Text(L("ask.tool.approvalHint"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 8)
                    Button(L("ask.deny")) { model.approve(conversationId: id, allowed: false) }
                    if model.canAllowForConversation(id) {
                        Button(L("ask.allowConversation")) { model.approveForConversation(id) }
                            .help(L("ask.allowConversation.help"))
                    }
                    Button(L("ask.allowOnce")) { model.approve(conversationId: id, allowed: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        // Resolved once per render: asking each row would rescan the transcript.
        let regenerable = model.regenerableAnswerId
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(transcriptMessages) { message in
                            AskMessageView(message: message,
                                           allMessages: model.selected?.messages ?? [],
                                           onReference: { model.addReference($0) },
                                           usage: message.runId.flatMap { model.selected?.usage?.runs[$0] },
                                           onUsage: { usageRunId = message.runId; setUsage(true) },
                                           isStreaming: message.id == model.selected?.run?.assistantId && model.selected?.run?.isActive == true,
                                           canRegenerate: regenerable == message.id,
                                           onRegenerate: { model.regenerate(message.id) },
                                           approvalToolId: model.selectedId.flatMap { model.pendingApprovals[$0]?.id })
                                .id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: AskTranscriptFrames.self,
                                                           value: [message.id: geometry.frame(in: .named("ask-transcript"))])
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
                    if let id { proxy.scrollTo(id, anchor: .center); model.referenceLocation = nil }
                }
                .onChange(of: model.selectedId) { _ in restoredTranscript = nil }
                .onChange(of: model.selected?.id) { _ in restoreTranscript(proxy) }
                .onAppear { restoreTranscript(proxy) }
                .onChange(of: model.selected?.run?.preview) { _ in followBottom(proxy) }
                .onChange(of: model.inferenceProgress) { _ in followBottom(proxy) }
                .onChange(of: model.selected?.messages.count) { _ in followBottom(proxy) }
            }
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
    let allMessages: [AskMessage]
    var onReference: (AskReference) -> Void
    var usage: AskUsageTotals? = nil
    var onUsage: () -> Void = {}
    var isStreaming = false
    var canRegenerate = false
    var onRegenerate: () -> Void = {}
    var approvalToolId: String? = nil
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
                if let references = message.references, !references.isEmpty { AskSentReferences(references: references) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(StudioTheme.textPrimary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(AskTheme.bubbleSurface, in: AskBubbleShape())
                        .overlay(AskBubbleShape().strokeBorder(AskTheme.border))
                }
                if message.image != nil || message.selection != nil { attachments }
            }
            .frame(maxWidth: AskMetrics.bubbleMaxWidth, alignment: .trailing)
        }
    }

    private var attachments: some View {
        HStack(spacing: 8) {
            if let text = message.selection {
                AskChip(title: L("ask.selection.lines", AskPresentation.lineCount(text)),
                        systemImage: "text.cursor",
                        action: { showSelection = true })
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
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 88, height: 56)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.border))
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
            if message.isError == true { interruptedTag }
            ForEach(message.toolCalls ?? []) { call in
                toolCard(call)
                    .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
            }
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
            AskGhostButton(title: copied ? L("ask.copied") : L("ask.copy"),
                           systemImage: copied ? "checkmark" : "doc.on.doc", active: copied) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            // An interrupted answer already offers this on its tag.
            if canRegenerate, message.isError != true {
                AskGhostButton(title: L("ask.regenerate"), systemImage: "arrow.clockwise", action: onRegenerate)
            }
            AskGhostButton(title: L("ask.quote"), systemImage: "text.quote") {
                onReference(AskReference(messageId: message.id, text: message.text, question: ""))
            }
            AskGhostButton(title: usageLabel, systemImage: "chart.bar.xaxis", action: onUsage)
        }
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var usageLabel: String {
        guard let usage else { return L("ask.usage.title") }
        return usage.creditsText + " credits"
    }

    private func toolCard(_ call: AskToolCall) -> some View {
        let result = allMessages.first { $0.toolCallId == call.id }
        return AskToolCard(
            title: AskTheme.toolTitle(call),
            subtitle: call.function.name,
            systemImage: AskPresentation.toolSymbol(call),
            state: isStreaming ? .running : (approvalToolId == call.id ? .attention : AskPresentation.toolState(result: result)),
            statusText: isStreaming ? L("ask.tool.preparing") : (approvalToolId == call.id ? L("ask.tool.pending") : AskPresentation.toolStatusText(result: result))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                AskMonoBlock(title: L("ask.tool.arguments"), text: call.function.arguments)
                if let result {
                    if !result.text.isEmpty {
                        AskMonoBlock(title: L("ask.tool.result"), text: result.text, isError: result.isError == true)
                    }
                    if let url = result.image, let image = AskImage.decode(url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

/// Reasoning is a single quiet line above the answer. It used to take a full
/// disclosure row plus a boxed body; now it only costs height once expanded.
private struct AskReasoningView: View {
    let text: String
    let milliseconds: Int
    let active: Bool
    @State private var expanded = false

    private var label: String {
        active ? L("ask.reasoning.active") : L("ask.reasoning.complete", max(1, milliseconds / 1000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "sparkle").font(.system(size: 10))
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                    if active { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(StudioTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    var onSelect: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.8, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(updatedAt, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .opacity(hovering ? 0 : 1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selection is a raised fill, concentric with the panel; no accent bar.
            .background(rowFill, in: RoundedRectangle(cornerRadius: AskMetrics.sidebarRowCorner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AskMetrics.sidebarRowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
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
            .padding(.trailing, 8)
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

    private var rowFill: Color {
        if selected { return AskTheme.selectionFill }
        return hovering ? AskTheme.hoverFill : .clear
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
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var corner: CGFloat { 18 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage).font(.system(size: 14))
                        .foregroundStyle(hovering ? Color.white : tint)
                        .frame(width: 30, height: 30)
                        .background(hovering ? tint : tint.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer(minLength: 8)
                    Text(verbatim: "⌘" + shortcut).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                Text(title).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .askInWindowGlass(corner: Self.corner, opaqueFill: AskTheme.composerSurface)
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = isEnabled && $0 }
        .accessibilityLabel(title)
        .accessibilityHint(caption)
    }
}
