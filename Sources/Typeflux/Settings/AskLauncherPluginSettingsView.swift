import SwiftUI

/// Edits the launcher's keywords for one plugin. Pure, so renaming, adding and
/// removing can be tested without the settings window.
struct AskKeywordList: Equatable {
    var keywords: [AskKeyword]

    func keywords(for pluginID: String) -> [AskKeyword] {
        keywords.filter { $0.pluginID == pluginID }
    }

    /// Renames `keyword`, or says why it cannot be: empty, a space, taken…
    mutating func rename(_ keyword: AskKeyword, to text: String) -> AskKeywordMatcher.Problem? {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard let index = keywords.firstIndex(of: keyword) else { return nil }
        if word.lowercased() == keyword.keyword.lowercased() {
            return nil
        }
        let others = keywords.enumerated().filter { $0.offset != index }.map(\.element)
        if let problem = AskKeywordMatcher.problem(with: word, among: others) {
            return problem
        }
        keywords[index].keyword = word
        return nil
    }

    /// A new keyword for the plugin, named after its first one plus a number.
    @discardableResult
    mutating func add(pluginID: String) -> AskKeyword {
        let base = keywords(for: pluginID).first?.keyword ?? "kw"
        var number = 2
        while keywords.contains(where: { $0.keyword.lowercased() == "\(base)\(number)" }) {
            number += 1
        }
        let keyword = AskKeyword(keyword: "\(base)\(number)", pluginID: pluginID)
        keywords.append(keyword)
        return keyword
    }

    mutating func remove(_ keyword: AskKeyword) {
        keywords.removeAll { $0 == keyword }
    }

    mutating func update(_ keyword: AskKeyword, _ change: (inout AskKeyword) -> Void) {
        guard let index = keywords.firstIndex(of: keyword) else { return }
        change(&keywords[index])
    }

    /// Sets an option, removing it when the text is empty so the keyword's preset shows through.
    mutating func set(_ option: String, to value: String, on keyword: AskKeyword) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        update(keyword) { $0.options[option] = trimmed.isEmpty ? nil : value }
    }

    /// Saves a web search URL template, or says why it cannot be used.
    mutating func setURL(_ template: String, on keyword: AskKeyword) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let problem = AskWebSearchPlugin.problem(with: trimmed) {
            return problem
        }
        set(AskWebSearchPlugin.urlOption, to: trimmed, on: keyword)
        return nil
    }

    static func message(for problem: AskKeywordMatcher.Problem) -> String {
        switch problem {
        case .empty: L("ask.settings.keywords.problem.empty")
        case .tooLong: L("ask.settings.keywords.problem.tooLong", AskKeywordMatcher.maximumLength)
        case .whitespace: L("ask.settings.keywords.problem.whitespace")
        case .slash: L("ask.settings.keywords.problem.slash")
        case .duplicate: L("ask.settings.keywords.problem.duplicate")
        }
    }
}

/// Settings → Launcher → Keywords: built-in and custom plugin keywords.
/// Workflow keywords stay on the workflow page, but still reserve their names when saving.
struct AskLauncherPluginSettingsView: View {
    let settings: SettingsStore
    @ObservedObject var workflows: AskWorkflowStore

    @State private var list = AskKeywordList(keywords: [])
    @State private var secondLanguage = "en"
    @State private var filter: AskKeywordKind?
    @State private var query: String
    @State private var editing: AskKeywordSheetItem?
    @State private var adding = false
    @State private var confirmingRestore = false

    init(settings: SettingsStore, workflows: AskWorkflowStore, initialFilter: AskKeywordKind? = nil,
         initialQuery: String = "") {
        self.settings = settings
        self.workflows = workflows
        _filter = State(initialValue: initialFilter == .workflow ? nil : initialFilter)
        _query = State(initialValue: initialQuery)
    }

    private var interface: AppLanguage {
        AppLocalization.shared.language
    }

    private var workflowEntries: [AskWorkflowKeywordEntry] {
        AskKeywordListPresentation.workflowEntries(workflows.workflows) { workflows.isEnabled($0) }
    }

    private var rows: [AskKeywordListRow] {
        AskKeywordListPresentation.rows(keywords: list.keywords,
                                        interface: interface, secondLanguage: secondLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            listCard
            Text(L("ask.settings.keywords.listFootnote"))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 4)
            Button(L("ask.settings.keywords.restore")) { confirmingRestore = true }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ModelVisualStyle.accent)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("ask.settings.keywords.restore")
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { item in
            AskKeywordEditorSheet(
                draft: item.draft, keywords: list.keywords, workflows: workflowEntries,
                onSave: { save($0, replacing: item.draft.original) },
                onDelete: item.draft.isNew ? nil : { remove(item.draft.original) },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(L("ask.settings.keywords.restoreTitle"), isPresented: $confirmingRestore) {
            Button(L("ask.settings.keywords.restore"), role: .destructive, action: restoreDefaults)
        } message: {
            Text(L("ask.settings.keywords.restoreMessage"))
        }
    }

    // MARK: - Toolbar

    /// Filters, search and "Add keyword" on one row, or the filters above the
    /// other two when the pane is narrow (the settings window's default width).
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterBar
                Spacer(minLength: 8)
                searchAndAdd
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    filterBar
                    ScrollView(.horizontal, showsIndicators: false) { filterBar }.frame(height: 30)
                }
                HStack(spacing: 8) {
                    searchAndAdd
                }
            }
        }
        .popover(isPresented: $adding, arrowEdge: .bottom) { addMenu }
    }

    private var filterBar: some View {
        AskKeywordFilterBar(selection: $filter, counts: AskKeywordListPresentation.counts(rows))
    }

    @ViewBuilder private var searchAndAdd: some View {
        SettingsSearchBox(placeholder: L("ask.settings.keywords.search"), text: $query, width: 200)
        Button { adding = true } label: {
            Label(L("ask.settings.keywords.add"), systemImage: "plus")
        }
        .buttonStyle(ModelActionStyle(primary: true))
        .fixedSize()
        .accessibilityIdentifier("ask.settings.keywords.add")
    }

    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([AskKeywordKind.translate, .prompt, .web], id: \.self) { kind in
                addItem(kind, title: kind.title) {
                    adding = false
                    editing = AskKeywordSheetItem(draft: AskKeywordDraft(adding: kind))
                }
            }
        }
        .padding(6).frame(width: 300)
    }

    private func addItem(_ kind: AskKeywordKind, title: String, action: @escaping () -> Void) -> some View {
        AskKeywordMenuItem(kind: kind, title: title, action: action)
    }

    // MARK: - List

    private var listCard: some View {
        let shown = AskKeywordListPresentation.filter(rows, kind: filter, query: query)
        return ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    AgentSettingsEmptyRow(text: L("ask.settings.keywords.noMatch", query))
                }
                ForEach(AskKeywordKind.editableKinds, id: \.self) { kind in
                    let group = shown.filter { $0.kind == kind }
                    if !group.isEmpty {
                        if filter == nil {
                            AskKeywordGroupHeader(kind: kind, first: shown.first?.kind == kind)
                        }
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                ModelRowDivider(leading: 16)
                            }
                            AskKeywordRowView(row: row, toggle: { toggle(row) }, open: { open(row) })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func open(_ row: AskKeywordListRow) {
        editing = AskKeywordSheetItem(draft: AskKeywordDraft(editing: row.source))
    }

    private func toggle(_ row: AskKeywordListRow) {
        list.update(row.source) { $0.enabled.toggle() }
        persist()
    }

    private func save(_ keyword: AskKeyword, replacing original: AskKeyword?) {
        list.save(keyword, replacing: original)
        persist()
        editing = nil
    }

    private func remove(_ keyword: AskKeyword?) {
        if let keyword {
            list.remove(keyword)
        }
        persist()
        editing = nil
    }

    private func restoreDefaults() {
        list = AskKeywordList(keywords: AskPluginRegistry.defaultKeywords)
        settings.saveAskLauncherKeywords(nil)
    }

    private func reload() {
        list = AskKeywordList(keywords: settings.effectiveAskLauncherKeywords(reserving: workflows.workflows))
        secondLanguage = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: interface)
    }

    private func persist() {
        settings.saveAskLauncherKeywords(list.keywords)
    }
}

/// A keyword sheet to present: a fresh id each time, so reopening the same keyword shows its saved values.
struct AskKeywordSheetItem: Identifiable {
    let id = UUID()
    var draft: AskKeywordDraft
}
