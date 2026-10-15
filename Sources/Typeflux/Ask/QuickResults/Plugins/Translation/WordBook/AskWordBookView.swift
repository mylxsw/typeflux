import SwiftUI

// swiftlint:disable file_length type_body_length

/// The word book uses the notebook's continuous columns and shared controls.
struct AskWordBookView: View {
    @ObservedObject var model: AskWordBookViewModel
    var onClose: () -> Void
    @State private var showsSidebar = false
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var regenerating: AskWordBookEntry?
    @FocusState private var focus: Field?
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    enum Field: Hashable { case lookup, filter }

    static let sidebarWidth = AskLibraryLayout.sidebarWidth
    static let lookupWidth: CGFloat = 380
    static let compactWidth = AskLibraryLayout.sidebarCollapseWidth

    static func isCompact(_ width: CGFloat) -> Bool { width < compactWidth }

    var body: some View {
        GeometryReader { proxy in
            let layout = AskLibraryLayout(width: proxy.size.width)
            HStack(spacing: 0) {
                if layout.sidebarInline {
                    sidebar(clearsTitleBar: true)
                        .askSidePanel(edge: .leading)
                        .frame(width: layout.sidebarWidth, height: proxy.size.height)
                        .clipped()
                }
                list(sidebarCollapsed: !layout.sidebarInline)
                    .frame(width: layout.listWidth, height: proxy.size.height)
                    .clipped()
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(AskTheme.librarySeparator).frame(width: colorScheme == .light ? 1 : 0.5)
                    }
                VStack(spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        lookupField.frame(maxWidth: Self.lookupWidth)
                    }
                    .padding(.leading, 22).padding(.trailing, 12)
                    .frame(height: AskMetrics.titleBarRowHeight)
                    .zIndex(2)
                    detailColumn
                }
                .frame(width: layout.detailWidth, height: proxy.size.height)
                .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: layout.sidebarInline) { inline in if inline { showsSidebar = false } }
        }
        .background(AskWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .background(shortcuts)
        .onChange(of: model.shelf) { _ in showsSidebar = false }
        .tint(AskTheme.accent)
        .alert(L("ask.wordBook.regenerate.title"), isPresented: Binding(
            get: { regenerating != nil }, set: { if !$0 { regenerating = nil } }
        ), presenting: regenerating) { entry in
            Button(L("ask.wordBook.regenerate")) { Task { await model.regenerate(entry) } }
            Button(L("ask.workflow.cancel"), role: .cancel) {}
        } message: { entry in
            Text(L("ask.wordBook.regenerate.message", entry.headword, model.modelName()))
        }
        .confirmationDialog(L("ask.wordBook.settings.clear.confirm", max(0, (model.counts[.all] ?? 0)
                - (model.counts[.starred] ?? 0))), isPresented: $confirmsClear) {
            Button(L("ask.wordBook.settings.clear"), role: .destructive) { model.clearHistory() }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .accessibilityIdentifier("ask.wordBook")
    }

    // MARK: - Sidebar

    private func sidebar(clearsTitleBar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: clearsTitleBar
                ? AskMetrics.sidebarTopInset : 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    groupTitle("ask.wordBook.shelf.library")
                    shelfRow(.all, symbol: "book.closed")
                    shelfRow(.starred, symbol: "star")
                    shelfRow(.today, symbol: "sun.max")
                    shelfRow(.week, symbol: "calendar")
                    if !model.pairs.isEmpty {
                        groupTitle("ask.wordBook.shelf.languages")
                        ForEach(model.pairs, id: \.self) { pair in
                            shelfRow(.pair(pair), symbol: "globe")
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            sidebarFooter
        }
        .accessibilityIdentifier("ask.wordBook.sidebar")
    }

    private func groupTitle(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private func shelfRow(_ shelf: AskWordBookViewModel.Shelf, symbol: String) -> some View {
        AskNotesShelfRow(title: model.title(of: shelf), symbol: symbol, count: model.counts[shelf] ?? 0,
                         tint: shelf == .starred ? AskWordBookStyle.star : nil,
                         active: model.shelf == shelf) {
            model.shelf = shelf
        }
    }

    /// Usage and controls live directly on the sidebar, like the notebook footer.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(model.streak)").font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(StudioTheme.textPrimary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("ask.wordBook.streak")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                    Text(L("ask.wordBook.weekTotal", model.weekTotal)).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            weekBars
            HStack(spacing: 2) {
                Image(systemName: "lock").font(.system(size: 10))
                Text(L("ask.wordBook.localOnly")).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 4)
                exportMenu
                settingsButton
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.top, 6)
            .overlay(alignment: .top) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 6)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 0.5) }
    }

    private var weekBars: some View {
        let peak = max(1, model.week.max() ?? 1)
        let labels = L("ask.wordBook.weekdays").split(separator: ",").map(String.init)
        let today = model.todayIndex
        return HStack(spacing: 4) {
            ForEach(Array(model.week.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(colorScheme == .light ? Color.black.opacity(0.06) : AskWordBookStyle.hover)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(colorScheme == .light || index == today
                                ? StudioTheme.accent : StudioTheme.textTertiary.opacity(0.55))
                            .frame(height: count == 0 ? 0 : max(5, 20 * CGFloat(count) / CGFloat(peak)))
                    }
                    .frame(height: 20)
                    Text(labels.indices.contains(index) ? labels[index] : "").font(.system(size: 9.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ask.wordBook.weekTotal", model.weekTotal))
    }

    private var exportMenu: some View {
        Menu {
            ForEach(AskWordBookExporter.Format.allCases) { format in
                Button(format.title) { model.export(format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(StudioTheme.textSecondary)
        .frame(width: 26, height: 26)
        .help(L("ask.wordBook.export"))
        .accessibilityLabel(L("ask.wordBook.export"))
    }

    private var settingsButton: some View {
        Button { showsSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(AskWordBookHoverStyle())
        .help(L("ask.wordBook.settings"))
        .accessibilityLabel(L("ask.wordBook.settings"))
        .popover(isPresented: $showsSettings, arrowEdge: .top) { settingsPopover }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(title: "ask.wordBook.settings.record", detail: "ask.wordBook.settings.record.detail") {
                Toggle("", isOn: $model.recordsHistory).toggleStyle(.switch).labelsHidden()
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.horizontal, 10)
            settingsRow(title: "ask.wordBook.settings.retention", detail: "ask.wordBook.settings.retention.detail") {
                Picker("", selection: $model.retention) {
                    ForEach(AskWordBookRetention.allCases, id: \.self) { retention in
                        Text(retention.days.map { L("ask.wordBook.settings.days", $0) } ?? L("ask.wordBook.settings.forever"))
                            .tag(retention)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.vertical, 4)
            Button(role: .destructive) {
                showsSettings = false
                confirmsClear = true
            } label: {
                Text(L("ask.wordBook.settings.clear") + "…").foregroundStyle(StudioTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AskWordBookHoverStyle())
        }
        .padding(8)
        .frame(width: 360)
    }

    private func settingsRow<Control: View>(title: String, detail: String,
                                            @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.system(size: 13))
                Text(L(detail)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(10)
    }

    // MARK: - Column headers

    private func navigationBar() -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: AskResultWindowView.trafficLightClearance)
            AskIconGhostButton(label: L("ask.sidebar.toggle"), systemImage: "sidebar.left") {
                showsSidebar.toggle()
            }
            .accessibilityIdentifier("ask.wordBook.sidebarToggle")
            .popover(isPresented: $showsSidebar, arrowEdge: .leading) {
                sidebar(clearsTitleBar: false)
                    .frame(width: Self.sidebarWidth, height: 480)
                    .background(AskTheme.glassFill)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private func listHeader(sidebarCollapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Text(model.title(of: model.shelf)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(L("ask.wordBook.wordCount", model.entries.count)).font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Picker(L("ask.wordBook.sort"), selection: $model.sort) {
                    Text(L("ask.wordBook.sort.recent")).tag(AskWordBookQuery.Sort.recent)
                    Text(L("ask.wordBook.sort.count")).tag(AskWordBookQuery.Sort.count)
                    Text(L("ask.wordBook.sort.alphabetical")).tag(AskWordBookQuery.Sort.alphabetical)
                    Text(L("ask.wordBook.sort.starred")).tag(AskWordBookQuery.Sort.starred)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(StudioTheme.textTertiary).fixedSize()
            .help(L("ask.wordBook.sort"))
            .accessibilityLabel(L("ask.wordBook.sort"))
        }
        .padding(.leading, 18).padding(.trailing, 10)
        .frame(height: sidebarCollapsed ? 40 : AskMetrics.titleBarRowHeight)
    }

    // MARK: - Lookup field

    private var lookupField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            TextField(L("ask.wordBook.lookup.placeholder"), text: $model.lookupText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .lookup)
                .onSubmit { Task { await model.lookUp() } }
                .accessibilityIdentifier("ask.wordBook.lookup")
            if model.lookingUp != nil {
                ProgressView().controlSize(.small)
            } else if focus != .lookup {
                keyHint("⌘L")
            }
            Button(action: model.cycleTarget) {
                HStack(spacing: 4) {
                    Text(model.directionTitle).font(.system(size: 11.5)).lineLimit(1)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10))
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 8).frame(height: 24)
                .frame(maxWidth: 160)
                .askWordBookControl()
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .help(L("ask.wordBook.lookup.direction"))
            .accessibilityLabel(L("ask.wordBook.lookup.direction"))
        }
        .askLibrarySearchSurface(focused: focus == .lookup)
        .overlay(alignment: .topLeading) { previewList.offset(y: style.ask.searchFieldHeight + 5) }
        .task(id: model.lookupText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.refreshPreview()
        }
    }

    /// What Return will do with the typed word, shown under the field like a menu.
    @ViewBuilder private var previewList: some View {
        if focus == .lookup, let preview = model.preview, model.lookingUp == nil {
            HStack(spacing: 8) {
                switch preview {
                case let .kept(meanings):
                    Text(L("ask.wordBook.lookup.kept")).foregroundStyle(StudioTheme.textTertiary)
                    Text(meanings).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    keyHint("↩")
                    Text(L("ask.wordBook.lookup.open")).foregroundStyle(StudioTheme.textTertiary)
                case let .device(translation):
                    Text(L("ask.plugin.source.device")).foregroundStyle(StudioTheme.textTertiary)
                    Text(translation).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    keyHint("↩")
                    Text(L("ask.wordBook.lookup.card")).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).frame(height: 32)
            .background(AskWordBookStyle.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(5)
            .askWordBookPopover(corner: StudioTheme.CornerRadius.medium)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
            .accessibilityIdentifier("ask.wordBook.preview")
        }
    }

    // MARK: - List

    private func list(sidebarCollapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if sidebarCollapsed { navigationBar() }
            listHeader(sidebarCollapsed: sidebarCollapsed)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.wordBook.search"), text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focus, equals: .filter)
                    .accessibilityIdentifier("ask.wordBook.search")
                AskKeyHint(text: "⌘F")
            }
            .askLibrarySearchSurface(focused: focus == .filter)
            .help(L("ask.wordBook.search") + "  ⌘F")
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !model.recordsHistory {
                            Label(L("ask.wordBook.paused"), systemImage: "pause.circle")
                                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AskWordBookStyle.hover,
                                            in: RoundedRectangle(cornerRadius: AskWordBookStyle.fieldCorner))
                                .padding(.vertical, 4)
                        }
                        if model.entries.isEmpty { emptyList }
                        ForEach(model.sections) { section in
                            if let period = section.period {
                                Text(period.title).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                            }
                            ForEach(section.entries) { entry in
                                let selected = isSelected(entry)
                                AskWordBookRow(entry: entry,
                                               selected: selected,
                                               select: { model.selectedKey = entry.key },
                                               star: { model.toggleStar(entry) })
                                    .id(entry.key)
                                    .onAppear { if entry.key == model.entries.last?.key { model.loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 70)
                }
                .onChange(of: model.selectedKey) { key in
                    if let key { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(key) } }
                }
            }
        }
        .accessibilityIdentifier("ask.wordBook.list")
    }

    private func isSelected(_ entry: AskWordBookEntry) -> Bool {
        model.transient == nil && entry.key == model.selectedKey
    }

    private var emptyList: some View {
        Text(model.filterText.isEmpty
            ? L(model.shelf == .starred ? "ask.wordBook.empty.starred" : "ask.wordBook.empty.shelf")
            : L("ask.wordBook.empty.search"))
            .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.top, 30)
    }

    // MARK: - Detail

    private var detailColumn: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let word = model.lookingUp {
                    loadingCard(word)
                } else if let entry = model.displayed {
                    AskWordBookDetail(model: model, entry: entry, regenerate: { regenerating = $0 })
                } else if (model.counts[.all] ?? 0) == 0 {
                    ScrollView(.vertical) { emptyBook }
                } else {
                    Text(L("ask.wordBook.choose")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            noticeToast.padding(.bottom, 66)
        }
    }

    private func loadingCard(_ word: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("ask.wordBook.lookup.writing", model.modelName()))
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 7).frame(height: 19)
                .background(AskWordBookStyle.hover, in: Capsule())
                Text(word).font(.system(size: 30, weight: .bold)).foregroundStyle(StudioTheme.textPrimary)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                AskWordBookSectionTitle(text: L("ask.wordBook.meanings"))
                skeleton([0.6, 0.85, 0.4])
                AskWordBookSectionTitle(text: L("ask.plugin.wordCard.examples"))
                skeleton([0.75, 0.5])
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.wordBook.loading")
    }

    private func skeleton(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                RoundedRectangle(cornerRadius: 4).fill(AskWordBookStyle.hover).frame(height: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, anchor: .leading)
            }
        }
        .padding(14)
        .askWordBookGroup()
    }

    private var emptyBook: some View {
        VStack(spacing: 0) {
            Image(systemName: "character.book.closed").font(.system(size: 22)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 56, height: 56)
                .background(StudioTheme.controlSurface,
                            in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero, style: .continuous)
                    .strokeBorder(StudioTheme.border))
            Text(L("ask.wordBook.emptyBook.title")).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary).padding(.top, 14)
            Text(L("ask.wordBook.emptyBook.detail")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                tip("⌘L", "ask.wordBook.tip.lookup")
                Rectangle().fill(StudioTheme.border).frame(height: 1)
                tip("⌥Space", "ask.wordBook.tip.dict")
                Rectangle().fill(StudioTheme.border).frame(height: 1)
                tip("⌘S", "ask.wordBook.tip.star")
            }
            .askWordBookGroup()
            .frame(maxWidth: 380)
            .padding(.top, 20)
            Button { focus = .lookup } label: {
                Label(L("ask.wordBook.firstLookup"), systemImage: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(StudioTheme.accent,
                                in: RoundedRectangle(cornerRadius: AskWordBookStyle.controlCorner, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity).padding(.top, 70)
        .accessibilityIdentifier("ask.wordBook.emptyBook")
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            keyHint(key).frame(minWidth: 52)
            Text(L(text)).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private var noticeToast: some View {
        if let notice = model.notice {
            HStack(spacing: 12) {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                if !model.deleted.isEmpty {
                    Button(L("ask.wordBook.undo")) { model.undoDelete() }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.horizontal, 14).frame(height: 34)
            .askWordBookPopover(corner: AskWordBookStyle.fieldCorner)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(model.deleted.isEmpty ? 2.5 : 5))
                if model.notice == notice { withAnimation { model.notice = nil } }
            }
            .accessibilityIdentifier("ask.wordBook.notice")
        }
    }

    // MARK: - Keys

    /// Keys without visible buttons: ⌘L, ⌘F, ↑↓, ⌘S, ⌘C, ⌫, ⌘Z and esc.
    private var shortcuts: some View {
        let typing = focus != nil
        return ZStack {
            Button("") { focus = .lookup }.keyboardShortcut("l")
            Button("") { focus = .filter }.keyboardShortcut("f")
            Button("") { model.moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: []).disabled(typing)
            Button("") { model.moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: []).disabled(typing)
            Button("") { if let entry = model.displayed { model.toggleStar(entry) } }.keyboardShortcut("s")
            Button("") { if let entry = model.displayed { model.copyMeaning(entry) } }
                .keyboardShortcut("c").disabled(typing)
            Button("") { if let entry = model.displayed { model.delete(entry) } }
                .keyboardShortcut(.delete, modifiers: []).disabled(typing)
            Button("") { model.undoDelete() }.keyboardShortcut("z").disabled(model.deleted.isEmpty || typing)
            Button("") { escape() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// esc: clears the lookup, then leaves the field, then closes the window.
    private func escape() {
        if focus == .lookup, !model.lookupText.isEmpty {
            model.lookupText = ""
        } else if focus != nil {
            focus = nil
        } else {
            onClose()
        }
    }

    private func keyHint(_ key: String) -> some View {
        AskWordBookKeyHint(key: key)
    }
}

/// One word in the list: headword, phonetic, one line of meanings, star and count.
struct AskWordBookRow: View {
    var entry: AskWordBookEntry
    var selected: Bool
    var select: () -> Void
    var star: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.headword).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    if let phonetic = entry.lookup.card?.phonetics.first?.text {
                        Text(phonetic).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    if entry.lookup.card == nil {
                        Text(L("ask.plugin.source.device")).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(AskWordBookStyle.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(entry.lookup.summary).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: star) {
                    Image(systemName: entry.isStarred ? "star.fill" : "star").font(.system(size: 12))
                        .foregroundStyle(entry.isStarred ? AskWordBookStyle.star : StudioTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .opacity(entry.isStarred || hovering || selected ? 1 : 0)
                .accessibilityLabel(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star"))
                if entry.lookupCount > 1 {
                    Text("×\(entry.lookupCount)").font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .askNotesRow(selected: selected, hovering: hovering, corner: 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen word scrolls on the window surface, with a floating action bar below.
struct AskWordBookDetail: View {
    @ObservedObject var model: AskWordBookViewModel
    var entry: AskWordBookEntry
    var regenerate: (AskWordBookEntry) -> Void

    private var format: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        hero(compact: geometry.size.width < 520)
                        meta
                    }
                    .padding(.bottom, 18)
                    Rectangle().fill(AskTheme.separator).frame(height: 0.5)
                    if let card = entry.lookup.card {
                        senses(card)
                        if !card.examples.isEmpty { examples(card) }
                        if !card.synonyms.isEmpty || !card.forms.isEmpty { related(card) }
                    } else {
                        plain
                    }
                    if !model.isTransient(entry) { history }
                }
                .frame(maxWidth: AskLibraryLayout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, geometry.size.width < 520 ? 18 : 36)
                .padding(.top, 6).padding(.bottom, 90)
            }
            .overlay(alignment: .bottom) { toolbar(width: geometry.size.width) }
        }
        .accessibilityIdentifier("ask.wordBook.detail")
    }

    private var meta: some View {
        AskWordBookFlow(spacing: 6) {
            Text(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: entry.lookup.source,
                                                                       target: entry.lookup.target),
                                                in: model.interfaceLanguage()))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            if model.isTransient(entry) {
                badge(L("ask.wordBook.badge.loose"))
            } else if model.freshKey == entry.key {
                badge(L("ask.wordBook.badge.new"), accent: true)
            } else {
                badge(L("ask.wordBook.badge.count", entry.lookupCount))
            }
            badge(entry.lookup.card != nil ? L("ask.wordBook.cardBy", entry.lookup.model ?? "AI") : L("ask.wordBook.plain"))
        }
    }

    /// A neutral pill; only a new word uses the accent.
    private func badge(_ text: String, accent: Bool = false) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? StudioTheme.accent : StudioTheme.textSecondary).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 19)
            .background(accent ? StudioTheme.accentSoft : AskWordBookStyle.hover, in: Capsule())
    }

    private func hero(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text(entry.headword).font(.system(size: AskLibraryLayout.titleSize(compact: compact), weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                AskWordBookFlow(spacing: 6) {
                    if let phonetics = entry.lookup.card?.phonetics, !phonetics.isEmpty {
                        ForEach(Array(phonetics.enumerated()), id: \.offset) { _, phonetic in
                            sound(label: phonetic.label, text: phonetic.text,
                                  language: AskWordCardView.voice(for: phonetic, default: AskWordBookViewModel.spokenLanguage(entry)))
                        }
                    } else {
                        sound(label: "", text: L("ask.plugin.action.speak"), language: AskWordBookViewModel.spokenLanguage(entry))
                    }
                }
            }
            Spacer(minLength: 8)
            Button { model.toggleStar(entry) } label: {
                ViewThatFits(in: .horizontal) {
                    starLabel(compact: false)
                    starLabel(compact: true)
                }
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .help(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star") + " ⌘S")
            .accessibilityLabel(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star"))
            .accessibilityIdentifier("ask.wordBook.star")
        }
    }

    private func starLabel(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isStarred ? "star.fill" : "star")
                .foregroundStyle(entry.isStarred ? AskWordBookStyle.star : StudioTheme.textSecondary)
            if !compact {
                Text(L(entry.isStarred ? "ask.wordBook.starredLabel" : "ask.wordBook.star"))
                Text("⌘S").font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(.horizontal, 11).frame(height: 28)
        .askWordBookControl()
        .contentShape(Rectangle())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sound(label: String, text: String, language: String) -> some View {
        Button { model.speakText(entry.headword, language) } label: {
            HStack(spacing: 6) {
                if !label.isEmpty { Text(label).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
                Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                Image(systemName: "speaker.wave.2").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .askWordBookControl()
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .accessibilityLabel(L("ask.plugin.action.speak") + " " + label)
    }

    /// Actions float over scrolling content, as in the notebook.
    private func toolbar(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            if width >= 600 { toolbarActions(compact: false).fixedSize(horizontal: true, vertical: false) }
            toolbarActions(compact: true).fixedSize(horizontal: true, vertical: false)
        }
        .askLibraryActionSurface()
        .accessibilityIdentifier("ask.wordBook.actions")
    }

    private func toolbarActions(compact: Bool) -> some View {
        HStack(spacing: 2) {
            toolbarButton("doc.on.doc", "ask.plugin.action.copyDefinition", key: "⌘C", compact: compact) { model.copyMeaning(entry) }
            toolbarButton("speaker.wave.2", "ask.plugin.action.speak", compact: compact) { model.speak(entry) }
            if model.askAI != nil {
                toolbarButton("bubble.left", "ask.quick.askAI", compact: compact) { model.ask(about: entry) }
            }
            if model.canRegenerate {
                toolbarButton(entry.lookup.card == nil ? "sparkles" : "arrow.clockwise",
                              entry.lookup.card == nil ? "ask.plugin.action.wordCard" : "ask.plugin.action.regenerate", compact: compact) {
                    regenerate(entry)
                }
                .disabled(model.regenerating != nil)
            }
            Rectangle().fill(AskTheme.separator).frame(width: 0.5, height: 16).padding(.horizontal, 4)
            toolbarButton("trash", model.isTransient(entry) ? "ask.wordBook.dismiss" : "ask.wordBook.delete", compact: compact) {
                model.delete(entry)
            }
            .accessibilityIdentifier("ask.wordBook.delete")
        }
        .padding(.horizontal, 6).frame(height: 40)
    }

    private func toolbarButton(_ symbol: String, _ title: String, key: String? = nil, compact: Bool = false,
                               action: @escaping () -> Void) -> some View {
        AskLibraryBarButton(title: L(title), symbol: symbol, key: key, compact: compact, action: action)
    }

    private func senses(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.meanings"), hint: L("ask.wordBook.copyMeaning"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.senses.enumerated()), id: \.offset) { index, sense in
                    if index > 0 { Rectangle().fill(StudioTheme.border).frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(sense.pos).font(.system(size: 12, weight: .semibold)).italic()
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(width: 44, alignment: .leading)
                        AskWordBookFlow(spacing: 4) {
                            ForEach(Array(sense.meanings.enumerated()), id: \.offset) { position, meaning in
                                Button { model.copyText(meaning) } label: {
                                    Text(meaning)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .font(.system(size: 14.5, weight: index == 0 && position == 0 ? .semibold : .regular))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AskWordBookChipStyle())
                                .help(L("ask.wordBook.copyMeaning"))
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .askWordBookGroup()
        }
    }

    private func examples(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.plugin.wordCard.examples"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.examples.enumerated()), id: \.offset) { index, example in
                    if index > 0 { Rectangle().fill(StudioTheme.border).frame(height: 1) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AskWordCardView.emphasized(example.source)).font(.system(size: 13.5))
                                .foregroundStyle(StudioTheme.textPrimary)
                            if !example.target.isEmpty {
                                Text(example.target).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                            }
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            model.speakText(AskWordCardView.plain(example.source), AskWordBookViewModel.spokenLanguage(entry))
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(AskWordBookHoverStyle())
                        .accessibilityLabel(L("ask.plugin.action.speak"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            .askWordBookGroup()
        }
    }

    private func related(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.related"))
            AskWordBookFlow(spacing: 6) {
                ForEach(card.synonyms, id: \.self) { word in chip(word, label: nil) }
                ForEach(Array(card.forms.enumerated()), id: \.offset) { _, form in chip(form.value, label: form.label) }
            }
        }
    }

    private func chip(_ word: String, label: String?) -> some View {
        AskWordBookRelatedChip(word: word, label: label) {
            Task { await model.lookUp(word) }
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.plain"), hint: L("ask.wordBook.copyMeaning"))
            Button { model.copyText(entry.lookup.translation ?? "") } label: {
                Text(entry.lookup.translation ?? "").font(.system(size: 14.5)).foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .askWordBookGroup()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.canRegenerate, AskWordCard.isLookup(entry.headword) {
                HStack(spacing: 10) {
                    Text(L("ask.wordBook.plainHint")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    Button { regenerate(entry) } label: {
                        Label(L("ask.plugin.action.wordCard"), systemImage: "sparkles").font(.system(size: 12.5))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .padding(.horizontal, 10).frame(height: 28)
                            .askWordBookControl()
                    }
                    .buttonStyle(StudioInteractiveButtonStyle())
                }
                .padding(.top, 10)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.history"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 0)], alignment: .leading, spacing: 0) {
                fact("ask.wordBook.fact.count", L("ask.wordBook.times", entry.lookupCount))
                fact("ask.wordBook.fact.first", entry.firstLookedUpAt.formatted(format), divided: true)
                fact("ask.wordBook.fact.last", entry.lastLookedUpAt.formatted(format), divided: true)
                if let starred = entry.starredAt {
                    fact("ask.wordBook.fact.starred", starred.formatted(format), divided: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .askWordBookGroup()
        }
    }

    private func fact(_ label: String, _ value: String, divided: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(label)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            Text(value).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if divided { Rectangle().fill(StudioTheme.border).frame(width: 1) }
        }
    }
}

/// A small caption above a group of rows, with an optional hint after it.
struct AskWordBookSectionTitle: View {
    var text: String
    var hint: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(text).fontWeight(.semibold)
            if let hint { Text("· " + hint) }
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.top, 16).padding(.bottom, 8)
    }
}

/// A keyboard shortcut drawn as a small key cap.
struct AskWordBookKeyHint: View {
    var key: String

    var body: some View { AskKeyHint(text: key) }
}

/// The word book's surfaces, all taken from the main window's theme.
enum AskWordBookStyle {
    static let hover = AskTheme.hoverFill
    static let star = Color.yellow
    static let fieldCorner = StudioTheme.CornerRadius.small
    static let controlCorner: CGFloat = 7
    static let cardCorner = StudioTheme.CornerRadius.large
}

extension View {
    /// Rows grouped inside a card, outlined.
    func askWordBookGroup() -> some View {
        modifier(AskWordBookGroupSurface())
    }

    /// Quiet controls belong to the content surface, rather than individual glass panels.
    func askWordBookControl() -> some View {
        background(AskTheme.hoverFill,
                   in: RoundedRectangle(cornerRadius: AskWordBookStyle.controlCorner, style: .continuous))
    }

    /// A menu-like surface that floats above the page.
    func askWordBookPopover(corner: CGFloat) -> some View {
        return askInWindowGlass(corner: corner, elevation: .popover)
    }
}

private struct AskWordBookGroupSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
        if colorScheme == .light {
            content.background(shape.fill(.white))
                .overlay(shape.strokeBorder(AskTheme.cardBorder, lineWidth: 1))
        } else {
            content.overlay(shape.strokeBorder(StudioTheme.border))
        }
    }
}

/// Lays chips out in rows, wrapping at the available width.
struct AskWordBookFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = measured(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func measured(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, max(0, width)), height: nil))
    }

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = measured(subviews[index], width: maxWidth)
            if !row.indices.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A gentle press: the control shrinks a little and darkens.
struct AskWordBookPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AskWordBookStyle.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: AskWordBookStyle.controlCorner, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A plain control that gets a neutral fill on hover, like toolbar buttons in the main window.
struct AskWordBookHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, corner: AskWordBookStyle.controlCorner)
    }
}

/// A meaning that lights up on hover; clicking copies it.
struct AskWordBookChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, corner: 5)
    }
}

private struct HoverLabel: View {
    let configuration: ButtonStyleConfiguration
    var corner: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(hovering && isEnabled ? AskWordBookStyle.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
