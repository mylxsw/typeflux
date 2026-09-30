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
    @AppStorage("ask.sidebarCollapsed") private var sidebarCollapsed = false
    @ObservedObject private var auth = AuthState.shared

    init(model: AskConversationModel, showsUsage: Bool = false) {
        self.model = model
        _showsUsage = State(initialValue: showsUsage)
        _usageRunId = State(initialValue: model.selected?.run?.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    sidebar.frame(width: AskMetrics.sidebarWidth)
                }
                content
                if showsUsage {
                    AskUsagePanel(model: model, runId: $usageRunId, close: { showsUsage = false })
                        .id(model.selectedId)
                }
            }
            titleBarTools
            if isSearching { searchPalette }
        }
        // Lay out from the very top of the window so the tools share the
        // traffic lights' baseline instead of sitting below the title bar.
        .onChange(of: model.selectedId) { _ in usageRunId = nil }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: showsUsage ? 1070 : 740, minHeight: 530)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window uses a full-size content view; this strip clears the
            // traffic lights. The toggle and search buttons float above it.
            Color.clear.frame(height: AskMetrics.sidebarTopInset)
            sidebarSearchField.padding(.horizontal, 10).padding(.bottom, 8)
            newConversationButton.padding(.horizontal, 10).padding(.bottom, 8)
            historyList
            accountFooter
        }
        .background(AskWindowBackdrop(role: .sidebar))
    }

    /// Toggle and search live in the title bar row. Expanded, they are right-aligned
    /// inside the sidebar; collapsed, they follow the traffic lights.
    private var titleBarTools: some View {
        HStack(spacing: 2) {
            if !sidebarCollapsed { Spacer(minLength: 0) }
            titleBarButton("sidebar.left", label: L("ask.sidebar.toggle")) {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
            }
            // Expanded, the sidebar owns the search entry; collapsed, it moves here.
            if sidebarCollapsed {
                titleBarButton("magnifyingglass", label: L("ask.search")) { openSearch() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        .padding(.leading, sidebarCollapsed ? AskMetrics.trafficLightInset : 0)
        .padding(.trailing, sidebarCollapsed ? 0 : 10)
        .frame(width: sidebarCollapsed ? nil : AskMetrics.sidebarWidth, alignment: .leading)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private func titleBarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AskTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        HStack(spacing: 10) {
            Text(accountName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
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
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
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
            Color.black.opacity(0.32)
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
            .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AskTheme.border))
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

    private var newConversationButton: some View {
        Button {
            model.newConversation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                    .frame(width: 18)
                Text(L("ask.new")).font(.system(size: 13.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(model.selectedId == nil ? StudioTheme.sidebarSelection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ask.new"))
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
        let selected = model.selectedId == item.id
        return Button {
            Task { await model.select(item.id) }
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 12.8, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.busyIds.contains(item.id) { ProgressView().controlSize(.mini) }
                else {
                    Text(item.updatedAt, style: .time)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioTheme.sidebarSelection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(AskTheme.accent).frame(width: 3, height: 16) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L("ask.delete"), role: .destructive) { deleteId = item.id }
                .disabled(model.busyIds.contains(item.id))
        }
    }

    private func historyGroup(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("ask.today") }
        if Calendar.current.isDateInYesterday(date) { return L("ask.yesterday") }
        return L("ask.earlier")
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            if model.selectedId == nil { emptyState } else { transcript }
            statusArea
            composerArea
        }
        .frame(minWidth: 480)
        .background(AskWindowBackdrop(role: .content))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.selected?.title
                 ?? model.conversations.first(where: { $0.id == model.selectedId })?.title
                 ?? L("ask.new"))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if model.isLoadingSelection, model.selected != nil { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if let id = model.selectedId {
                Button { usageRunId = model.selected?.run?.id; showsUsage.toggle() } label: {
                    Label(L("ask.usage.title"), systemImage: "chart.bar.xaxis").font(.system(size: 11))
                }.buttonStyle(.plain).help(L("ask.usage.title"))
                Button { deleteId = id } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 27, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.delete"))
                .accessibilityLabel(L("ask.delete"))
            }
        }
        .padding(.leading, sidebarCollapsed ? AskMetrics.collapsedTitleInset : 18)
        .padding(.trailing, 18)
        .frame(height: AskMetrics.titleBarRowHeight)
        .frame(height: AskMetrics.headerHeight, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L("ask.empty")).font(.system(size: 22, weight: .semibold))
            Text(L("ask.empty.hint")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            VStack(spacing: 8) {
                suggestion(title: L("ask.suggest.screen"), caption: L("ask.suggest.screen.caption"),
                           systemImage: "display", shortcut: "1", screenshot: true)
                suggestion(title: L("ask.suggest.selection"), caption: L("ask.suggest.selection.caption"),
                           systemImage: "text.cursor", shortcut: "2", screenshot: false)
                suggestion(title: L("ask.suggest.page"), caption: L("ask.suggest.page.caption"),
                           systemImage: "globe", shortcut: "3", screenshot: false)
            }
            .frame(width: 380)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    /// The caption used to sit at the trailing edge in the faintest grey in the
    /// window, where it read as a disabled tag. It belongs under its own title.
    /// This is a hotkey-summoned tool, so each row carries a real shortcut;
    /// Command-digit rather than Option-digit, which types a character.
    private func suggestion(title: String, caption: String, systemImage: String,
                            shortcut: String, screenshot: Bool) -> some View {
        Button {
            model.draft.text = title
            if screenshot { model.draft.includeScreenshot = true }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage).font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    Text(caption).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                AskKeyCap(text: "⌘" + shortcut)
            }
            .padding(.horizontal, 11)
            .frame(height: 52)
            .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(AskTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: .command)
        .disabled(screenshot && model.screenshotCapability(launcher: false) != .supported)
        .help(screenshot ? (model.screenshotCapability(launcher: false).hint ?? caption) : caption)
        .accessibilityLabel(title)
        .accessibilityHint(caption)
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
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }
        if let id = model.selected?.id, let call = model.pendingApprovals[id] {
            approval(call, id: id).padding(.horizontal, 22).padding(.bottom, 6)
        }
        if let target = model.imageRecoveryTarget {
            AskImageRecoveryCard(model: model, target: target)
                .id(target.id)
                .padding(.horizontal, 22).padding(.bottom, 6)
        } else if !model.hasPendingSubmission, let run = model.selected?.run, run.status == "failed" || run.status == "cancelled", !model.isBusy {
            AskBanner(text: run.error ?? L("ask.cancelled"), tone: .info,
                      systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
        } else if resumable, model.error == nil {
            AskBanner(text: L("ask.resume.hint"), tone: .info, systemImage: "arrow.clockwise",
                      actionTitle: L("ask.resume"), action: { model.resume() })
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
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
                    .background(AskTheme.raisedSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(AskTheme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.stop"))
            }
            // The context budget used to occupy a whole row of its own below the
            // composer; it now rides in the footer next to the send button.
            AskComposer(model: model, launcher: false, onOpenUsage: { showsUsage = true })
                .disabled(model.isLoadingSelection)
        }
        .frame(maxWidth: AskMetrics.composerMaxWidth)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
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
                    LazyVStack(alignment: .leading, spacing: 19) {
                        if model.isLoadingSelection, model.selected == nil {
                            ProgressView(L("ask.loading")).controlSize(.small)
                                .frame(maxWidth: .infinity).padding(.top, 24)
                        }
                        ForEach(transcriptMessages) { message in
                            AskMessageView(message: message,
                                           allMessages: model.selected?.messages ?? [],
                                           onReference: { model.addReference($0) },
                                           usage: message.runId.flatMap { model.selected?.usage?.runs[$0] },
                                           onUsage: { usageRunId = message.runId; showsUsage = true },
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
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AskTranscriptFrames.self,
                                                       value: ["bottom": geometry.frame(in: .named("ask-transcript"))])
                            })
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 20)
                }
                .coordinateSpace(name: "ask-transcript")
                .onPreferenceChange(AskTranscriptFrames.self) { frames in
                    guard let id = model.selectedId, restoredTranscript == id else { return }
                    if let bottom = frames["bottom"], bottom.minY <= viewport.size.height + 24 {
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
            restoredTranscript = id
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
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 8) {
                if let references = message.references, !references.isEmpty { AskSentReferences(references: references) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(AskTheme.bubbleSurface,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            if message.isError == true {
                Text(L("ask.answer.interrupted"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
            ForEach(message.toolCalls ?? []) { call in
                toolCard(call)
                    .frame(maxWidth: AskMetrics.transcriptMaxWidth, alignment: .leading)
            }
            if !message.text.isEmpty, !isStreaming { turnActions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
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
            if canRegenerate {
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
