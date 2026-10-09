import SwiftUI

// swiftlint:disable file_length type_body_length

/// The word book window, drawn as one more page of the main window: a flat sidebar of
/// shelves, a page header with the lookup field, the list card and the chosen word's card
/// (`docs/design/word-book-studio.md`).
struct AskWordBookView: View {
    @ObservedObject var model: AskWordBookViewModel
    var onClose: () -> Void
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var regenerating: AskWordBookEntry?
    @FocusState private var focus: Field?

    enum Field: Hashable { case lookup, filter }

    static let sidebarWidth = StudioTheme.sidebarWidth
    static let compactSidebarWidth: CGFloat = 60
    static let listWidth: CGFloat = 300
    static let compactListWidth: CGFloat = 260
    static let lookupWidth: CGFloat = 380
    static let compactLookupWidth: CGFloat = 330
    /// Narrower windows fold the sidebar into a column of icons.
    static let compactWidth: CGFloat = 980
    static let fieldHeight: CGFloat = 32
    /// Room for the traffic lights above the shelves.
    static let trafficLightClearance: CGFloat = 44

    static func isCompact(_ width: CGFloat) -> Bool { width < compactWidth }

    var body: some View {
        GeometryReader { proxy in
            let compact = Self.isCompact(proxy.size.width)
            HStack(spacing: 0) {
                sidebar(compact: compact)
                    .frame(width: compact ? Self.compactSidebarWidth : Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(AskWordBookBackground(fill: StudioTheme.sidebar))
                    .overlay(alignment: .trailing) { Rectangle().fill(StudioTheme.border).frame(width: 1) }
                page(compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AskWordBookBackground(fill: StudioTheme.shellSurface))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(shortcuts)
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

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.trafficLightClearance)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    groupTitle("ask.wordBook.shelf.library", compact: compact)
                    shelfRow(.all, symbol: "book.closed", compact: compact)
                    shelfRow(.starred, symbol: "star", compact: compact)
                    shelfRow(.today, symbol: "sun.max", compact: compact)
                    shelfRow(.week, symbol: "calendar", compact: compact)
                    if !model.pairs.isEmpty {
                        groupTitle("ask.wordBook.shelf.languages", compact: compact)
                        ForEach(model.pairs, id: \.self) { pair in
                            shelfRow(.pair(pair), symbol: "globe", compact: compact)
                        }
                    }
                }
                .padding(.horizontal, compact ? 10 : 12)
            }
            if compact {
                VStack(spacing: 4) {
                    exportMenu
                    settingsButton
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            } else {
                sidebarFooter
            }
        }
        .accessibilityIdentifier("ask.wordBook.sidebar")
    }

    @ViewBuilder private func groupTitle(_ key: String, compact: Bool) -> some View {
        if compact {
            Color.clear.frame(height: 10)
        } else {
            Text(L(key)).font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private func shelfRow(_ shelf: AskWordBookViewModel.Shelf, symbol: String, compact: Bool) -> some View {
        let active = model.shelf == shelf
        let title = model.title(of: shelf)
        return Button {
            model.shelf = shelf
        } label: {
            HStack(spacing: 10) {
                Image(systemName: active && shelf == .starred ? "star.fill" : symbol)
                    .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                    .foregroundStyle(active && shelf == .starred ? AskWordBookStyle.star
                        : active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .frame(width: 18)
                if !compact {
                    Text(title).font(.studioBody(StudioTheme.Typography.body, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(model.counts[shelf] ?? 0)").font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, compact ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .frame(height: 34)
            .background(active ? AskWordBookStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: AskWordBookStyle.fieldCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .help(compact ? title : "")
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Streak, this week's bars and the book's own controls, in a card like the main window's account card.
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
        .background(StudioTheme.cardSurface,
                    in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
            .strokeBorder(StudioTheme.border))
        .padding(12)
    }

    private var weekBars: some View {
        let peak = max(1, model.week.max() ?? 1)
        let labels = L("ask.wordBook.weekdays").split(separator: ",").map(String.init)
        let today = model.todayIndex
        return HStack(spacing: 4) {
            ForEach(Array(model.week.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(AskWordBookStyle.hover)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(index == today ? StudioTheme.accent : StudioTheme.textTertiary.opacity(0.55))
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
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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

    // MARK: - Page

    private func page(compact: Bool) -> some View {
        VStack(spacing: 0) {
            header(compact: compact)
                .padding(.horizontal, StudioTheme.contentInset)
                .padding(.top, 22)
                .zIndex(2)
            HStack(alignment: .top, spacing: 16) {
                list.frame(width: compact ? Self.compactListWidth : Self.listWidth).askWordBookCard()
                detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity).askWordBookCard()
            }
            .padding(.horizontal, StudioTheme.contentInset)
            .padding(.top, 14)
            .padding(.bottom, StudioTheme.contentInset)
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(model.title(of: model.shelf))
                .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
            Text(L("ask.wordBook.wordCount", model.entries.count)).font(.system(size: 13))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
            lookupField.frame(width: compact ? Self.compactLookupWidth : Self.lookupWidth)
        }
        .frame(height: 40)
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
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioTheme.border))
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .help(L("ask.wordBook.lookup.direction"))
            .accessibilityLabel(L("ask.wordBook.lookup.direction"))
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: Self.fieldHeight)
        .askWordBookField(focused: focus == .lookup, corner: AskWordBookStyle.fieldCorner)
        .overlay(alignment: .topLeading) { previewList.offset(y: Self.fieldHeight + 5) }
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
            .frame(width: Self.lookupWidth)
            .transition(.opacity)
            .accessibilityIdentifier("ask.wordBook.preview")
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                    TextField(L("ask.wordBook.search"), text: $model.filterText)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .focused($focus, equals: .filter)
                        .accessibilityIdentifier("ask.wordBook.search")
                }
                .padding(.horizontal, 8).frame(height: 28)
                .help(L("ask.wordBook.search") + "  ⌘F")
                .askWordBookField(focused: focus == .filter, corner: AskWordBookStyle.controlCorner,
                                  fill: StudioTheme.controlSurface)
                Picker(L("ask.wordBook.sort"), selection: $model.sort) {
                    Text(L("ask.wordBook.sort.recent")).tag(AskWordBookQuery.Sort.recent)
                    Text(L("ask.wordBook.sort.count")).tag(AskWordBookQuery.Sort.count)
                    Text(L("ask.wordBook.sort.alphabetical")).tag(AskWordBookQuery.Sort.alphabetical)
                    Text(L("ask.wordBook.sort.starred")).tag(AskWordBookQuery.Sort.starred)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .help(L("ask.wordBook.sort"))
            }
            .padding(10)
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                let selected = isSelected(entry)
                                AskWordBookRow(entry: entry,
                                               selected: selected,
                                               separated: index > 0 && !selected && !isSelected(section.entries[index - 1]),
                                               select: { model.selectedKey = entry.key },
                                               star: { model.toggleStar(entry) })
                                    .id(entry.key)
                                    .onAppear { if entry.key == model.entries.last?.key { model.loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 8)
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
            noticeToast.padding(.bottom, 16)
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
    /// Draws the hairline above the row; hidden next to the selected row.
    var separated = false
    var select: () -> Void
    var star: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.headword).font(.system(size: 13.5, weight: .semibold))
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
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? AskWordBookStyle.selection : hovering ? AskWordBookStyle.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: AskWordBookStyle.fieldCorner, style: .continuous))
        .overlay(alignment: .top) {
            if separated, !hovering {
                Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen word in one card: where it came from, the headword with its sounds and star,
/// a toolbar of actions, then meanings to copy, examples to hear, related words to look up
/// and its lookup history.
struct AskWordBookDetail: View {
    @ObservedObject var model: AskWordBookViewModel
    var entry: AskWordBookEntry
    var regenerate: (AskWordBookEntry) -> Void

    private var format: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                meta
                hero
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            toolbar
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let card = entry.lookup.card {
                        senses(card)
                        if !card.examples.isEmpty { examples(card) }
                        if !card.synonyms.isEmpty || !card.forms.isEmpty { related(card) }
                    } else {
                        plain
                    }
                    if !model.isTransient(entry) { history }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text(entry.headword).font(.system(size: 30, weight: .bold)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(2)
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
                HStack(spacing: 6) {
                    Image(systemName: entry.isStarred ? "star.fill" : "star")
                        .foregroundStyle(entry.isStarred ? AskWordBookStyle.star : StudioTheme.textSecondary)
                    Text(L(entry.isStarred ? "ask.wordBook.starredLabel" : "ask.wordBook.star"))
                    Text("⌘S").font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, 11).frame(height: 28)
                .askWordBookControl()
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioInteractiveButtonStyle())
            .accessibilityIdentifier("ask.wordBook.star")
        }
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

    /// The word's actions, fixed above its scrolling content.
    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("doc.on.doc", "ask.plugin.action.copyDefinition", key: "⌘C") { model.copyMeaning(entry) }
            toolbarButton("speaker.wave.2", "ask.plugin.action.speak") { model.speak(entry) }
            if model.askAI != nil {
                toolbarButton("bubble.left", "ask.quick.askAI") { model.ask(about: entry) }
            }
            if model.canRegenerate {
                toolbarButton(entry.lookup.card == nil ? "sparkles" : "arrow.clockwise",
                              entry.lookup.card == nil ? "ask.plugin.action.wordCard" : "ask.plugin.action.regenerate") {
                    regenerate(entry)
                }
                .disabled(model.regenerating != nil)
            }
            Spacer(minLength: 4)
            toolbarButton("trash", model.isTransient(entry) ? "ask.wordBook.dismiss" : "ask.wordBook.delete") {
                model.delete(entry)
            }
            .accessibilityIdentifier("ask.wordBook.delete")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityIdentifier("ask.wordBook.actions")
    }

    private func toolbarButton(_ symbol: String, _ title: String, key: String? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(L(title)).font(.system(size: 12.5)).lineLimit(1)
                if let key { Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(AskWordBookHoverStyle())
        .accessibilityLabel(L(title))
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
        Button { Task { await model.lookUp(word) } } label: {
            HStack(spacing: 5) {
                if let label, !label.isEmpty {
                    Text(label).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                }
                Text(word).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .askWordBookControl()
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .help(L("ask.wordBook.lookUpWord", word))
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
            HStack(alignment: .top, spacing: 0) {
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

    var body: some View {
        Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 5).frame(height: 18)
            .background(AskWordBookStyle.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(StudioTheme.border))
    }
}

/// The word book's surfaces, all taken from the main window's theme.
enum AskWordBookStyle {
    static let selection = StudioTheme.sidebarSelection
    static let hover = StudioTheme.sidebarSelection.opacity(0.55)
    static let star = Color.yellow
    static let fieldCorner = StudioTheme.CornerRadius.small
    static let controlCorner: CGFloat = 7
    static let cardCorner = StudioTheme.CornerRadius.large
}

/// The main window's backdrop: a material with the theme's tint on top.
struct AskWordBookBackground: View {
    var fill: Color

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            fill
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// A `StudioCard`-like container: card surface, thin border, 12-point corners.
    func askWordBookCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: AskWordBookStyle.cardCorner, style: .continuous)
        return background(StudioTheme.cardSurface, in: shape)
            .overlay(shape.strokeBorder(StudioTheme.border))
            .clipShape(shape)
    }

    /// Rows grouped inside a card, outlined.
    func askWordBookGroup() -> some View {
        overlay(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
            .strokeBorder(StudioTheme.border))
    }

    /// A small bordered button face.
    func askWordBookControl() -> some View {
        let shape = RoundedRectangle(cornerRadius: AskWordBookStyle.controlCorner, style: .continuous)
        return background(StudioTheme.controlSurface, in: shape).overlay(shape.strokeBorder(StudioTheme.border))
    }

    /// A text field's face; focus draws the accent border and a soft ring.
    func askWordBookField(focused: Bool, corner: CGFloat, fill: Color = StudioTheme.cardSurface) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return background(fill, in: shape)
            .overlay(shape.strokeBorder(focused ? StudioTheme.accent : StudioTheme.border))
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                        .fill(StudioTheme.accentSoft).padding(-3)
                }
            }
    }

    /// A menu-like surface that floats above the page.
    func askWordBookPopover(corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return background(StudioTheme.modalSurface, in: shape)
            .overlay(shape.strokeBorder(StudioTheme.border))
            .shadow(color: StudioTheme.shadow, radius: 12, y: 6)
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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
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
            let size = subviews[index].sizeThatFits(.unspecified)
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
