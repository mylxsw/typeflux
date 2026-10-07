import SwiftUI

/// The word book dialog: starred words or every lookup on the left, the chosen
/// word's card on the right, and what can be done with it.
struct AskWordBookView: View {
    @ObservedObject var model: AskWordBookViewModel
    var onClose: () -> Void
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var regenerating: AskWordBookEntry?
    @FocusState private var searchFocused: Bool

    static let listWidth: CGFloat = 330

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                list.frame(width: Self.listWidth)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(StudioTheme.windowBackground)
        .background(shortcuts)
        .sheet(isPresented: $showsSettings) { settingsSheet }
        .alert(L("ask.wordBook.regenerate.title"), isPresented: Binding(
            get: { regenerating != nil }, set: { if !$0 { regenerating = nil } }
        ), presenting: regenerating) { entry in
            Button(L("ask.wordBook.regenerate")) { Task { await model.regenerate(entry) } }
            Button(L("ask.workflow.cancel"), role: .cancel) {}
        } message: { entry in
            Text(L("ask.wordBook.regenerate.message", entry.headword, model.modelName()))
        }
        .accessibilityIdentifier("ask.wordBook")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.scope) {
                Text(L("ask.wordBook.scope.starred") + " \(model.starredCount)").tag(AskWordBookQuery.Scope.starred)
                Text(L("ask.wordBook.scope.all") + " \(model.totalCount)").tag(AskWordBookQuery.Scope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.wordBook.search"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("ask.wordBook.search")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Picker("", selection: $model.pair) {
                Text(L("ask.wordBook.allLanguages")).tag(AskWordBookLanguagePair?.none)
                ForEach(model.pairs, id: \.self) { pair in
                    Text(AskWordBookViewModel.pairTitle(pair, in: AppLocalization.shared.language))
                        .tag(AskWordBookLanguagePair?.some(pair))
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: $model.sort) {
                Text(L("ask.wordBook.sort.recent")).tag(AskWordBookQuery.Sort.recent)
                Text(L("ask.wordBook.sort.count")).tag(AskWordBookQuery.Sort.count)
                Text(L("ask.wordBook.sort.alphabetical")).tag(AskWordBookQuery.Sort.alphabetical)
                Text(L("ask.wordBook.sort.starred")).tag(AskWordBookQuery.Sort.starred)
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                ForEach(AskWordBookExporter.Format.allCases) { format in
                    Button(format.title) { model.export(format) }
                }
                Divider()
                Button(L("ask.wordBook.settings") + "…") { showsSettings = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L("ask.wordBook.more"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !model.recordsHistory, model.scope == .all {
                        Text(L("ask.wordBook.paused")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.entries.isEmpty { emptyList }
                    ForEach(model.sections) { section in
                        if let period = section.period {
                            Text(period.title).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioTheme.textTertiary)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                        }
                        ForEach(section.entries) { entry in
                            row(entry).id(entry.key)
                                .onAppear { if entry.key == model.entries.last?.key { model.loadMore() } }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedKey) { key in
                if let key { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(key) } }
            }
        }
        .accessibilityIdentifier("ask.wordBook.list")
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: model.searchText.isEmpty ? "star" : "magnifyingglass").font(.system(size: 26))
            Text(model.searchText.isEmpty && model.pair == nil
                ? L(model.scope == .starred ? "ask.wordBook.empty.starred" : "ask.wordBook.empty.all")
                : L("ask.wordBook.empty.search"))
                .multilineTextAlignment(.center)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(StudioTheme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func row(_ entry: AskWordBookEntry) -> some View {
        let selected = entry.key == model.selectedKey
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            VStack(alignment: .trailing, spacing: 3) {
                starButton(entry, size: 14)
                if entry.lookupCount > 1 {
                    Text("×\(entry.lookupCount)").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? AskTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedKey = entry.key }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func starButton(_ entry: AskWordBookEntry, size: CGFloat) -> some View {
        Button { model.toggleStar(entry) } label: {
            Image(systemName: entry.isStarred ? "star.fill" : "star").font(.system(size: size))
                .foregroundStyle(entry.isStarred ? Color.yellow : StudioTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star"))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selected {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: entry.lookup.source,
                                                                                   target: entry.lookup.target),
                                                            in: AppLocalization.shared.language))
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        Text(entry.lookup.card == nil ? L("ask.wordBook.plain")
                            : L("ask.wordBook.cardBy", entry.lookup.model ?? "AI"))
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 6).frame(height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AskTheme.separator))
                    }
                    Group {
                        if let card = entry.lookup.card {
                            AskWordCardView(card: card, language: entry.lookup.source ?? "en") { action in
                                switch action.kind {
                                case let .speak(text, language): model.speakText(text, language)
                                case let .copy(text):
                                    model.copy(text)
                                    model.notice = L("ask.plugin.copied")
                                default: break
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.headword).font(.system(size: 22, weight: .semibold))
                                Text(entry.lookup.translation ?? "").font(.system(size: 14.5)).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.separator))
                    facts(entry)
                    actions(entry)
                }
                .padding(20)
            }
        } else {
            Text(L("ask.wordBook.choose")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
        }
    }

    private func facts(_ entry: AskWordBookEntry) -> some View {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow { label("ask.wordBook.fact.count"); Text(L("ask.wordBook.times", entry.lookupCount)) }
            GridRow { label("ask.wordBook.fact.first"); Text(entry.firstLookedUpAt.formatted(format)) }
            GridRow { label("ask.wordBook.fact.last"); Text(entry.lastLookedUpAt.formatted(format)) }
            GridRow { label("ask.wordBook.fact.starred"); Text(entry.starredAt?.formatted(format) ?? "—") }
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioTheme.textSecondary)
    }

    private func label(_ key: String) -> some View {
        Text(L(key)).foregroundStyle(StudioTheme.textTertiary)
    }

    private func actions(_ entry: AskWordBookEntry) -> some View {
        HStack(spacing: 8) {
            Button { model.toggleStar(entry) } label: {
                Label(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star"),
                      systemImage: entry.isStarred ? "star.fill" : "star")
            }
            .accessibilityIdentifier("ask.wordBook.star")
            Button { model.speak(entry) } label: { Label(L("ask.plugin.action.speak"), systemImage: "speaker.wave.2") }
            Button { model.copyMeaning(entry) } label: {
                Label(L("ask.plugin.action.copyDefinition"), systemImage: "doc.on.doc")
            }
            if model.canRegenerate {
                Button { regenerating = entry } label: {
                    Label(L(entry.lookup.card == nil ? "ask.plugin.action.wordCard" : "ask.plugin.action.regenerate") + "…",
                          systemImage: entry.lookup.card == nil ? "sparkles" : "arrow.clockwise")
                }
                .disabled(model.regenerating != nil)
            }
            Button(role: .destructive) { model.delete(entry) } label: {
                Label(L("ask.wordBook.delete"), systemImage: "trash")
            }
            .accessibilityIdentifier("ask.wordBook.delete")
            if model.regenerating == entry.key { ProgressView().controlSize(.small) }
        }
        .controlSize(.regular)
    }

    // MARK: - Footer and keys

    private var footer: some View {
        HStack(spacing: 14) {
            Text(L("ask.wordBook.keys")).foregroundStyle(StudioTheme.textTertiary)
            Spacer()
            if let notice = model.notice {
                Text(notice).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                if !model.deleted.isEmpty {
                    Button(L("ask.wordBook.undo")) { model.undoDelete() }.buttonStyle(.link)
                }
            } else {
                Text(L("ask.wordBook.recent", model.recentCount)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    /// Keys without visible buttons: ↑↓, ⌘F, ⌘S, ⌫ and esc.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { model.moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { searchFocused = true }.keyboardShortcut("f")
            Button("") { if let entry = model.selected { model.toggleStar(entry) } }.keyboardShortcut("s")
            Button("") { if let entry = model.selected { model.delete(entry) } }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(searchFocused)
            Button("") { model.undoDelete() }.keyboardShortcut("z").disabled(model.deleted.isEmpty || searchFocused)
            Button("") { if searchFocused { searchFocused = false } else { onClose() } }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("ask.wordBook.settings")).font(.system(size: 15, weight: .semibold)).padding(16)
            Divider()
            settingsRow(title: "ask.wordBook.settings.record", detail: "ask.wordBook.settings.record.detail") {
                Toggle("", isOn: $model.recordsHistory).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            settingsRow(title: "ask.wordBook.settings.retention", detail: "ask.wordBook.settings.retention.detail") {
                Picker("", selection: $model.retention) {
                    ForEach(AskWordBookRetention.allCases, id: \.self) { retention in
                        Text(retention.days.map { L("ask.wordBook.settings.days", $0) } ?? L("ask.wordBook.settings.forever"))
                            .tag(retention)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            settingsRow(title: "ask.wordBook.settings.clear", detail: "ask.wordBook.settings.clear.detail") {
                Button(L("ask.wordBook.settings.clear") + "…", role: .destructive) { confirmsClear = true }
            }
            Divider()
            HStack {
                Spacer()
                Button(L("ask.wordBook.done")) { showsSettings = false }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 500)
        .confirmationDialog(L("ask.wordBook.settings.clear.confirm", model.totalCount - model.starredCount),
                            isPresented: $confirmsClear) {
            Button(L("ask.wordBook.settings.clear"), role: .destructive) { model.clearHistory() }
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
