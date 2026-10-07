import SwiftUI

// swiftlint:disable file_length type_body_length

/// The word book window in the Ask workspace's Liquid Glass style: a floating glass
/// sidebar of shelves, a glass lookup bar, the list, the chosen word's card, and a
/// glass action bar (`docs/design/word-book-redesign.md`).
struct AskWordBookView: View {
    @ObservedObject var model: AskWordBookViewModel
    var onClose: () -> Void
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var regenerating: AskWordBookEntry?
    @FocusState private var focus: Field?

    enum Field: Hashable { case lookup, filter }

    static let sidebarWidth: CGFloat = 232
    static let listWidth: CGFloat = 312
    static let barHeight: CGFloat = 38
    static let actionBarHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: Self.sidebarWidth)
            VStack(spacing: 0) {
                lookupBar
                    .frame(height: AskMetrics.sidebarTopInset)
                    .padding(.horizontal, 16)
                    .zIndex(2)
                HStack(spacing: 0) {
                    list.frame(width: Self.listWidth)
                    Rectangle().fill(AskTheme.separator).frame(width: 1)
                    detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(backdrop)
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
        }
        .accessibilityIdentifier("ask.wordBook")
    }

    /// The workspace's frosted window with a faint accent glow behind the sidebar.
    private var backdrop: some View {
        ZStack {
            AskWindowBackdrop()
            RadialGradient(colors: [AskTheme.accent.opacity(0.16), .clear], center: UnitPoint(x: 0.06, y: 0.16),
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.purple.opacity(0.12), .clear], center: UnitPoint(x: 0.16, y: 0.94),
                           startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the traffic lights, which sit in the panel's top strip.
            Color.clear.frame(height: AskMetrics.sidebarTopInset - AskMetrics.sidebarPanelInset)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    groupTitle("ask.wordBook.shelf.library")
                    shelfRow(.all, symbol: "book.closed")
                    shelfRow(.starred, symbol: "star")
                    shelfRow(.today, symbol: "sun.max")
                    shelfRow(.week, symbol: "calendar")
                    if !model.pairs.isEmpty {
                        groupTitle("ask.wordBook.shelf.languages")
                        ForEach(model.pairs, id: \.self) { pair in shelfRow(.pair(pair), symbol: "globe") }
                    }
                }
                .padding(.horizontal, 8)
            }
            sidebarFooter
        }
        .askInWindowGlass(corner: AskMetrics.sidebarPanelCorner, opaqueFill: AskTheme.glassFill)
        .padding([.leading, .top, .bottom], AskMetrics.sidebarPanelInset)
        .accessibilityIdentifier("ask.wordBook.sidebar")
    }

    private func groupTitle(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }

    private func shelfRow(_ shelf: AskWordBookViewModel.Shelf, symbol: String) -> some View {
        let active = model.shelf == shelf
        return Button {
            model.shelf = shelf
        } label: {
            HStack(spacing: 9) {
                Image(systemName: active && shelf == .starred ? "star.fill" : symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(shelf == .starred ? Color.yellow : active ? AskTheme.accent : StudioTheme.textSecondary)
                    .frame(width: 18)
                Text(model.title(of: shelf)).font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(model.counts[shelf] ?? 0)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(active ? AskTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: AskMetrics.sidebarRowCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(model.streak)").font(.system(size: 22, weight: .bold).monospacedDigit())
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("ask.wordBook.streak")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    Text(L("ask.wordBook.weekTotal", model.weekTotal)).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            weekBars
            HStack(spacing: 4) {
                Text(L("ask.wordBook.localOnly")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Menu {
                    ForEach(AskWordBookExporter.Format.allCases) { format in
                        Button(format.title) { model.export(format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("ask.wordBook.export"))
                .accessibilityLabel(L("ask.wordBook.export"))
                Button { showsSettings.toggle() } label: {
                    Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.wordBook.settings"))
                .accessibilityLabel(L("ask.wordBook.settings"))
                .popover(isPresented: $showsSettings, arrowEdge: .top) { settingsPopover }
            }
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
    }

    private var weekBars: some View {
        let peak = max(1, model.week.max() ?? 1)
        let labels = L("ask.wordBook.weekdays").split(separator: ",").map(String.init)
        return HStack(spacing: 4) {
            ForEach(Array(model.week.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AskTheme.hoverFill)
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AskTheme.accent.opacity(0.6))
                            .frame(height: count == 0 ? 0 : max(5, 22 * CGFloat(count) / CGFloat(peak)))
                    }
                    .frame(height: 22)
                    Text(labels.indices.contains(index) ? labels[index] : "").font(.system(size: 9.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ask.wordBook.weekTotal", model.weekTotal))
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(title: "ask.wordBook.settings.record", detail: "ask.wordBook.settings.record.detail") {
                Toggle("", isOn: $model.recordsHistory).toggleStyle(.switch).labelsHidden()
            }
            settingsRow(title: "ask.wordBook.settings.retention", detail: "ask.wordBook.settings.retention.detail") {
                Picker("", selection: $model.retention) {
                    ForEach(AskWordBookRetention.allCases, id: \.self) { retention in
                        Text(retention.days.map { L("ask.wordBook.settings.days", $0) } ?? L("ask.wordBook.settings.forever"))
                            .tag(retention)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.vertical, 4)
            Button(role: .destructive) {
                showsSettings = false
                confirmsClear = true
            } label: {
                Text(L("ask.wordBook.settings.clear") + "…").foregroundStyle(StudioTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    // MARK: - Lookup bar

    private var lookupBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
            TextField(L("ask.wordBook.lookup.placeholder"), text: $model.lookupText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
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
                .padding(.horizontal, 10).frame(height: 26)
                .background(AskTheme.hoverFill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("ask.wordBook.lookup.direction"))
            .accessibilityLabel(L("ask.wordBook.lookup.direction"))
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: Self.barHeight)
        .askInWindowGlassPill(height: Self.barHeight)
        .overlay {
            if focus == .lookup {
                Capsule().strokeBorder(AskTheme.accent.opacity(0.5), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 560)
        .overlay(alignment: .bottom) { previewLine.offset(y: Self.barHeight - 4) }
        .task(id: model.lookupText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.refreshPreview()
        }
    }

    @ViewBuilder private var previewLine: some View {
        if focus == .lookup, let preview = model.preview, model.lookingUp == nil {
            HStack(spacing: 6) {
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
            .font(.system(size: 12))
            .padding(.horizontal, 14).frame(height: 30)
            .askInWindowGlass(corner: 12, opaqueFill: AskTheme.glassFill, elevation: .control)
            .frame(maxWidth: 560)
            .transition(.opacity)
            .accessibilityIdentifier("ask.wordBook.preview")
        }
    }

    private func keyHint(_ key: String) -> some View {
        Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 5).frame(height: 18)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.title(of: model.shelf)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(L("ask.wordBook.wordCount", model.entries.count)).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Picker(selection: $model.sort) {
                    Text(L("ask.wordBook.sort.recent")).tag(AskWordBookQuery.Sort.recent)
                    Text(L("ask.wordBook.sort.count")).tag(AskWordBookQuery.Sort.count)
                    Text(L("ask.wordBook.sort.alphabetical")).tag(AskWordBookQuery.Sort.alphabetical)
                    Text(L("ask.wordBook.sort.starred")).tag(AskWordBookQuery.Sort.starred)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .help(L("ask.wordBook.sort"))
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.top, 4).padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.wordBook.search"), text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focus, equals: .filter)
                    .accessibilityIdentifier("ask.wordBook.search")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !model.recordsHistory {
                            Text(L("ask.wordBook.paused")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if model.entries.isEmpty { emptyList }
                        ForEach(model.sections) { section in
                            if let period = section.period {
                                Text(period.title).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                            }
                            ForEach(section.entries) { entry in
                                AskWordBookRow(entry: entry,
                                               selected: model.transient == nil && entry.key == model.selectedKey,
                                               select: { model.selectedKey = entry.key },
                                               star: { model.toggleStar(entry) })
                                    .id(entry.key)
                                    .onAppear { if entry.key == model.entries.last?.key { model.loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
                .onChange(of: model.selectedKey) { key in
                    if let key { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(key) } }
                }
            }
        }
        .accessibilityIdentifier("ask.wordBook.list")
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
            ScrollView(.vertical) {
                Group {
                    if let word = model.lookingUp {
                        loadingCard(word)
                    } else if let entry = model.displayed {
                        AskWordBookDetail(model: model, entry: entry, regenerate: { regenerating = $0 })
                    } else if (model.counts[.all] ?? 0) == 0 {
                        emptyBook
                    } else {
                        Text(L("ask.wordBook.choose")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                            .frame(maxWidth: .infinity).padding(.top, 120)
                    }
                }
                .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 90)
            }
            VStack(spacing: 10) {
                noticeToast
                if model.lookingUp == nil, let entry = model.displayed { actionBar(entry) }
            }
            .padding(.bottom, 16)
        }
    }

    private func loadingCard(_ word: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.wordBook.lookup.writing", model.modelName())).font(.system(size: 11.5))
                .foregroundStyle(Color.purple).padding(.horizontal, 8).frame(height: 20)
                .background(Color.purple.opacity(0.14), in: Capsule())
            Text(word).font(.system(size: 34, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                ForEach([0.6, 0.85, 0.4], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 7).fill(AskTheme.hoverFill).frame(height: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: width, anchor: .leading)
                }
            }
            .padding(16)
            .background(StudioTheme.cardSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.wordBook.loading")
    }

    private var emptyBook: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed").font(.system(size: 32)).foregroundStyle(AskTheme.accent)
                .frame(width: 84, height: 84)
                .background(AskTheme.accentSoft, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text(L("ask.wordBook.emptyBook.title")).font(.system(size: 17, weight: .semibold))
            Text(L("ask.wordBook.emptyBook.detail")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                tip("⌘L", "ask.wordBook.tip.lookup")
                tip("⌥Space", "ask.wordBook.tip.dict")
                tip("⌘S", "ask.wordBook.tip.star")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity).padding(.top, 90)
        .accessibilityIdentifier("ask.wordBook.emptyBook")
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            keyHint(key)
            Text(L(text)).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
        }
    }

    private func actionBar(_ entry: AskWordBookEntry) -> some View {
        HStack(spacing: 2) {
            barButton("doc.on.doc", "ask.plugin.action.copyDefinition", key: "⌘C") { model.copyMeaning(entry) }
            barButton("speaker.wave.2", "ask.plugin.action.speak") { model.speak(entry) }
            if model.askAI != nil {
                barButton("bubble.left", "ask.quick.askAI") { model.ask(about: entry) }
            }
            if model.canRegenerate {
                barButton(entry.lookup.card == nil ? "sparkles" : "arrow.clockwise",
                          entry.lookup.card == nil ? "ask.plugin.action.wordCard" : "ask.plugin.action.regenerate") {
                    regenerating = entry
                }
                .disabled(model.regenerating != nil)
            }
            Rectangle().fill(AskTheme.separator).frame(width: 1, height: 18).padding(.horizontal, 3)
            barButton("trash", model.isTransient(entry) ? "ask.wordBook.dismiss" : "ask.wordBook.delete") {
                model.delete(entry)
            }
            .accessibilityIdentifier("ask.wordBook.delete")
        }
        .padding(.horizontal, 4)
        .frame(height: Self.actionBarHeight)
        .askInWindowGlassPill(height: Self.actionBarHeight)
        .accessibilityIdentifier("ask.wordBook.actions")
    }

    private func barButton(_ symbol: String, _ title: String, key: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5))
                Text(L(title)).font(.system(size: 12.5))
                if let key { Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
            }
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 10).frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(AskWordBookPressStyle())
        .accessibilityLabel(L(title))
    }

    @ViewBuilder private var noticeToast: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice).font(.system(size: 12.5)).lineLimit(1)
                if !model.deleted.isEmpty {
                    Button(L("ask.wordBook.undo")) { model.undoDelete() }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AskTheme.accent)
                }
            }
            .padding(.horizontal, 14).frame(height: 32)
            .askInWindowGlassPill(height: 32)
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
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.headword).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    if let phonetic = entry.lookup.card?.phonetics.first?.text {
                        Text(phonetic).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    if entry.lookup.card == nil {
                        Text(L("ask.wordBook.plain")).font(.system(size: 10)).foregroundStyle(StudioTheme.success)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(StudioTheme.success.opacity(0.4)))
                    }
                    Text(entry.lookup.summary).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: star) {
                    Image(systemName: entry.isStarred ? "star.fill" : "star").font(.system(size: 12.5))
                        .foregroundStyle(entry.isStarred ? Color.yellow : StudioTheme.textTertiary)
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
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? AskTheme.accentSoft : hovering ? AskTheme.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.accent.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen word: where it came from, the headword with its sounds, meanings to
/// copy, examples to hear, related words to look up, and its lookup history.
struct AskWordBookDetail: View {
    @ObservedObject var model: AskWordBookViewModel
    var entry: AskWordBookEntry
    var regenerate: (AskWordBookEntry) -> Void

    private var format: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            meta
            hero.padding(.top, 10)
            if let card = entry.lookup.card {
                senses(card).padding(.top, 18)
                if !card.examples.isEmpty { examples(card) }
                if !card.synonyms.isEmpty || !card.forms.isEmpty { related(card) }
            } else {
                plain
            }
            if !model.isTransient(entry) { history }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.wordBook.detail")
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: entry.lookup.source,
                                                                       target: entry.lookup.target),
                                                in: model.interfaceLanguage()))
                .foregroundStyle(StudioTheme.textSecondary)
            if model.isTransient(entry) {
                badge(L("ask.wordBook.badge.loose"), tint: StudioTheme.textSecondary)
            } else if model.freshKey == entry.key {
                badge(L("ask.wordBook.badge.new"), tint: AskTheme.accent)
            } else {
                badge(L("ask.wordBook.badge.count", entry.lookupCount), tint: StudioTheme.textSecondary)
            }
            if entry.lookup.card != nil {
                badge(L("ask.wordBook.cardBy", entry.lookup.model ?? "AI"), tint: .purple)
            } else {
                badge(L("ask.wordBook.plain"), tint: StudioTheme.success)
            }
        }
        .font(.system(size: 12))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 20)
            .background(tint.opacity(0.13), in: Capsule())
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.headword).font(.system(size: 34, weight: .bold)).lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
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
                    Text(L(entry.isStarred ? "ask.wordBook.starredLabel" : "ask.wordBook.star"))
                    Text("⌘S").font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                }
                .font(.system(size: 13))
                .foregroundStyle(entry.isStarred ? Color.yellow : StudioTheme.textPrimary)
                .padding(.horizontal, 14).frame(height: 34)
                .background(entry.isStarred ? Color.yellow.opacity(0.16) : AskTheme.hoverFill, in: Capsule())
                .overlay(Capsule().strokeBorder(entry.isStarred ? Color.yellow.opacity(0.5) : Color.clear))
                .contentShape(Capsule())
            }
            .buttonStyle(AskWordBookPressStyle())
            .accessibilityIdentifier("ask.wordBook.star")
        }
    }

    private func sound(label: String, text: String, language: String) -> some View {
        Button { model.speakText(entry.headword, language) } label: {
            HStack(spacing: 6) {
                if !label.isEmpty { Text(label).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
                Text(text).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                Image(systemName: "speaker.wave.2").font(.system(size: 10.5)).foregroundStyle(AskTheme.accent)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(AskTheme.hoverFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(AskWordBookPressStyle())
        .accessibilityLabel(L("ask.plugin.action.speak") + " " + label)
    }

    private func senses(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.senses.enumerated()), id: \.offset) { index, sense in
                if index > 0 { Rectangle().fill(AskTheme.separator).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sense.pos).font(.system(size: 12, weight: .bold)).italic().foregroundStyle(AskTheme.accent)
                        .frame(width: 48, alignment: .trailing)
                    AskWordBookFlow(spacing: 6) {
                        ForEach(Array(sense.meanings.enumerated()), id: \.offset) { position, meaning in
                            Button { model.copyText(meaning) } label: {
                                Text(meaning).font(.system(size: 15.5, weight: index == 0 && position == 0 ? .semibold : .regular))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(AskWordBookChipStyle())
                            .help(L("ask.wordBook.copyMeaning"))
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(StudioTheme.cardSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AskTheme.separator))
    }

    private func examples(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ask.plugin.wordCard.examples")
            ForEach(Array(card.examples.enumerated()), id: \.offset) { _, example in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AskWordCardView.emphasized(example.source)).font(.system(size: 14))
                        if !example.target.isEmpty {
                            Text(example.target).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                    .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.speakText(AskWordCardView.plain(example.source), AskWordBookViewModel.spokenLanguage(entry)) } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("ask.plugin.action.speak"))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(StudioTheme.cardSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.separator))
            }
        }
    }

    private func related(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ask.wordBook.related")
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
            .padding(.horizontal, 11).frame(height: 26)
            .background(AskTheme.hoverFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(AskWordBookChipStyle())
        .help(L("ask.wordBook.lookUpWord", word))
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.copyText(entry.lookup.translation ?? "") } label: {
                Text(entry.lookup.translation ?? "").font(.system(size: 15.5)).foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(StudioTheme.cardSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AskTheme.separator))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            if model.canRegenerate, AskWordCard.isLookup(entry.headword) {
                HStack(spacing: 8) {
                    Text(L("ask.wordBook.plainHint")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    Button { regenerate(entry) } label: {
                        Label(L("ask.plugin.action.wordCard"), systemImage: "sparkles").font(.system(size: 12.5))
                            .foregroundStyle(AskTheme.accent)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(AskTheme.accentSoft, in: Capsule())
                    }
                    .buttonStyle(AskWordBookPressStyle())
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ask.wordBook.history")
            // Wraps rather than squeezing the dates when the column is narrow.
            AskWordBookFlow(spacing: 18) {
                fact("ask.wordBook.fact.count", L("ask.wordBook.times", entry.lookupCount))
                fact("ask.wordBook.fact.first", entry.firstLookedUpAt.formatted(format))
                fact("ask.wordBook.fact.last", entry.lastLookedUpAt.formatted(format))
                if let starred = entry.starredAt { fact("ask.wordBook.fact.starred", starred.formatted(format)) }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(L(label)).foregroundStyle(StudioTheme.textTertiary)
            Text(value).fontWeight(.semibold).foregroundStyle(StudioTheme.textSecondary)
        }
        .font(.system(size: 12))
        .fixedSize()
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.top, 18)
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
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
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

/// A gentle press: the control shrinks a little and darkens, as the workspace's glass buttons do.
struct AskWordBookPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AskTheme.hoverFill : Color.clear, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A chip that lights up with the accent on hover.
struct AskWordBookChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AskWordBookChip(configuration: configuration)
    }

    private struct AskWordBookChip: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering ? AskTheme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
        }
    }
}
