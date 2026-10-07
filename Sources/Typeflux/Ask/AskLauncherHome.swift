import Foundation

/// What the launcher offers before anything is typed, built from what the user
/// is looking at: actions for the selected text or the open web page, the
/// conversations they may want to pick up, and the keywords they use most.
/// Pure, so every case can be tested without a window.
enum AskLauncherHome {
    /// What a row does when it is chosen.
    enum Action: Equatable {
        /// Enters a keyword's plugin and runs it on the selection, as `fy ` + Return would.
        case keyword(AskKeyword)
        /// Sends this question with the captured context.
        case ask(String)
        /// Opens a conversation in the workspace.
        case conversation(id: String)
    }

    enum Tint: Equatable {
        case accent, orange, purple, green, neutral
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String?
        var symbol: String
        var tint: Tint
        /// The keyword the row stands for, shown so it can be typed next time.
        var keyword: String?
        /// When the conversation was last active; nil for other rows.
        var date: Date?
        var action: Action
    }

    /// A keyword shown as a chip in the bottom section.
    struct Chip: Equatable, Identifiable {
        var keyword: AskKeyword
        var title: String
        var symbol: String

        var id: String { keyword.id }
    }

    enum Section: Equatable {
        /// Actions for the selection or page; `subtitle` says what they work on.
        case context(title: String, subtitle: String?, rows: [Row])
        case recent(rows: [Row])
        /// `teaching` lists the built-in keywords for someone who has not used any yet.
        case keywords(chips: [Chip], teaching: Bool)
    }

    /// A launcher keyword that can run, with what its chip calls it.
    struct KeywordChoice: Equatable {
        var keyword: AskKeyword
        var title: String
        var symbol: String
    }

    struct Context: Equatable {
        /// The selected text that rides with the question; nil when none.
        var selection: String?
        var sourceBundleID: String?
        /// The source window's title, for the page section.
        var windowTitle: String?
        /// Enabled keywords whose plugin is available, in the user's order.
        var keywords: [KeywordChoice] = []
        /// How much each keyword (by `AskKeyword.id`) has been used lately.
        var usage: [String: Double] = [:]
        var conversations: [AskConversationSummary] = []
        var now = Date()
    }

    /// Most rows in the context section.
    static let maximumContextRows = 4
    /// Conversations older than this are not offered to continue.
    static let recentWindow: TimeInterval = 24 * 60 * 60
    static let maximumChips = 6
    /// Keywords someone has used before the chips follow their usage instead of teaching.
    static let teachingThreshold = 3
    /// Text this long (or this many lines) is worth summarising.
    static let summaryCharacters = 200
    static let summaryLines = 3

    static func build(_ context: Context) -> [Section] {
        var sections: [Section] = []
        let contextSection = self.contextSection(context)
        var contextRows = 0
        if let contextSection, case let .context(_, _, rows) = contextSection {
            sections.append(contextSection)
            contextRows = rows.count
        }
        // Selected text is what the user came for; older conversations would only crowd it.
        let recent = hasSelection(context) ? [] : recentRows(context, budget: recentBudget(contextRows: contextRows))
        if !recent.isEmpty { sections.append(.recent(rows: recent)) }
        let (chips, teaching) = self.chips(context)
        if !chips.isEmpty { sections.append(.keywords(chips: chips, teaching: teaching)) }
        return sections
    }

    /// Fewer conversations when the context already offers a lot, more when it offers nothing.
    static func recentBudget(contextRows: Int) -> Int {
        switch contextRows {
        case 0: return 3
        case maximumContextRows...: return 1
        default: return 2
        }
    }

    // MARK: - Context

    private static func trimmedSelection(_ context: Context) -> String {
        context.selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func hasSelection(_ context: Context) -> Bool { !trimmedSelection(context).isEmpty }

    private static func contextSection(_ context: Context) -> Section? {
        let selection = trimmedSelection(context)
        if !selection.isEmpty { return selectionSection(selection, context: context) }
        if AskLocalTools.isSupportedBrowser(context.sourceBundleID) {
            let rows = [Row(id: "page.summary", title: L("ask.home.page.summary"),
                            detail: L("ask.home.page.summary.detail"), symbol: "doc.text.magnifyingglass",
                            tint: .orange, action: .ask(L("ask.home.page.summary.prompt")))]
            let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .context(title: L("ask.home.section.page"), subtitle: title?.isEmpty == false ? title : nil,
                            rows: rows)
        }
        return nil
    }

    private static func selectionSection(_ selection: String, context: Context) -> Section? {
        let lines = AskPresentation.lineCount(selection)
        let preview = "“" + AskContextChips.selectionPreview(selection) + "”"
        var rows: [Row] = []
        let title: String
        if AskWordCard.isLookup(selection) {
            title = L("ask.home.section.word")
            if let translate = translateKeyword(context.keywords) {
                rows.append(keywordRow(translate, id: "word.lookup", title: L("ask.home.word.lookup", selection),
                                       detail: L("ask.home.word.lookup.detail"), symbol: "character.book.closed",
                                       tint: .green))
            }
            rows.append(Row(id: "word.examples", title: L("ask.home.word.examples"), detail: nil,
                            symbol: "text.quote", tint: .orange, action: .ask(L("ask.home.word.examples.prompt"))))
            if let explain = promptKeyword(.explain, in: context.keywords) {
                rows.append(keywordRow(explain, id: "word.explain", title: L("ask.home.word.explain"),
                                       detail: nil, symbol: "lightbulb", tint: .purple))
            }
            return .context(title: title, subtitle: nil, rows: rows)
        }
        if CodingAppDetector.isCodingApp(bundleIdentifier: context.sourceBundleID) {
            title = L("ask.home.section.code", lines)
            if let explain = promptKeyword(.explain, in: context.keywords) {
                rows.append(keywordRow(explain, id: "code.explain", title: L("ask.home.code.explain"),
                                       detail: L("ask.home.code.explain.detail"), symbol: "curlybraces", tint: .accent))
            }
            rows.append(Row(id: "code.review", title: L("ask.home.code.review"),
                            detail: L("ask.home.code.review.detail"), symbol: "exclamationmark.triangle",
                            tint: .orange, action: .ask(L("ask.home.code.review.prompt"))))
            rows.append(Row(id: "code.tests", title: L("ask.home.code.tests"), detail: L("ask.home.code.tests.detail"),
                            symbol: "checkmark.seal", tint: .green, action: .ask(L("ask.home.code.tests.prompt"))))
            return .context(title: title, subtitle: preview, rows: Array(rows.prefix(maximumContextRows)))
        }
        title = L("ask.home.section.selection", lines)
        if let translate = translateKeyword(context.keywords) {
            rows.append(keywordRow(translate, id: "text.translate", title: L("ask.home.text.translate"),
                                   detail: L("ask.home.text.translate.detail"), symbol: "character.bubble",
                                   tint: .accent))
        }
        if selection.count >= summaryCharacters || lines >= summaryLines,
           let summarize = promptKeyword(.summarize, in: context.keywords) {
            rows.append(keywordRow(summarize, id: "text.summarize", title: L("ask.home.text.summarize"),
                                   detail: L("ask.home.text.summarize.detail"), symbol: "text.append", tint: .orange))
        }
        if let polish = promptKeyword(.polish, in: context.keywords) {
            rows.append(keywordRow(polish, id: "text.polish", title: L("ask.home.text.polish"),
                                   detail: L("ask.home.text.polish.detail"), symbol: "wand.and.stars", tint: .purple))
        }
        if let explain = promptKeyword(.explain, in: context.keywords) {
            rows.append(keywordRow(explain, id: "text.explain", title: L("ask.home.text.explain"),
                                   detail: nil, symbol: "lightbulb", tint: .green))
        }
        guard !rows.isEmpty else { return nil }
        return .context(title: title, subtitle: preview, rows: Array(rows.prefix(maximumContextRows)))
    }

    private static func keywordRow(_ choice: KeywordChoice, id: String, title: String, detail: String?,
                                   symbol: String, tint: Tint) -> Row {
        Row(id: id, title: title, detail: detail, symbol: symbol, tint: tint, keyword: choice.keyword.keyword,
            action: .keyword(choice.keyword))
    }

    /// The plain translation keyword: not the word book, and preferably without a preset language.
    static func translateKeyword(_ keywords: [KeywordChoice]) -> KeywordChoice? {
        let translations = keywords.filter {
            $0.keyword.pluginID == AskTranslatePlugin.id && !AskTranslatePlugin.opensWordBook($0.keyword.options)
        }
        return translations.first { $0.keyword.options[AskTranslatePlugin.targetOption] == nil } ?? translations.first
    }

    /// The keyword for a built-in prompt, unless the user has rewritten its prompt.
    static func promptKeyword(_ preset: AskPromptPlugin.Preset, in keywords: [KeywordChoice]) -> KeywordChoice? {
        keywords.first {
            let options = $0.keyword.options
            return $0.keyword.pluginID == AskPromptPlugin.id && options[AskPromptPlugin.presetOption] == preset.rawValue
                && (options[AskPromptPlugin.promptOption] ?? "").isEmpty
        }
    }

    // MARK: - Recent conversations

    private static func recentRows(_ context: Context, budget: Int) -> [Row] {
        context.conversations
            .filter { context.now.timeIntervalSince($0.updatedAt) <= recentWindow && !$0.title.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(budget)
            .map { Row(id: "conversation." + $0.id, title: $0.title, detail: nil, symbol: "arrow.uturn.backward",
                       tint: .neutral, date: $0.updatedAt, action: .conversation(id: $0.id)) }
    }

    // MARK: - Keywords

    /// The keywords used most, or the built-in ones while the user has used fewer than a few.
    static func chips(_ context: Context) -> (chips: [Chip], teaching: Bool) {
        let used = context.keywords.filter { (context.usage[$0.keyword.id] ?? 0) > 0 }
        if used.count >= teachingThreshold {
            // A stable sort keeps the user's order between keywords used equally.
            let ranked = used.enumerated().sorted { lhs, rhs in
                let left = context.usage[lhs.element.keyword.id] ?? 0
                let right = context.usage[rhs.element.keyword.id] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
            return (ranked.prefix(maximumChips).map(chip), false)
        }
        // One chip per built-in plugin action, in a fixed order.
        var teaching: [KeywordChoice] = []
        if let translate = translateKeyword(context.keywords) { teaching.append(translate) }
        for preset in [AskPromptPlugin.Preset.polish, .summarize] {
            if let keyword = promptKeyword(preset, in: context.keywords) { teaching.append(keyword) }
        }
        if let search = context.keywords.first(where: { $0.keyword.pluginID == AskWebSearchPlugin.id }) {
            teaching.append(search)
        }
        return (teaching.map(chip), true)
    }

    private static func chip(_ choice: KeywordChoice) -> Chip {
        Chip(keyword: choice.keyword, title: choice.title, symbol: choice.symbol)
    }
}

// MARK: - Navigation

extension AskLauncherHome {
    /// One stop for the keyboard: a row, or a chip in the chip row.
    enum Item: Equatable {
        case row(Row)
        case chip(Chip)

        var id: String {
            switch self {
            case let .row(row): return row.id
            case let .chip(chip): return "chip." + chip.id
            }
        }
    }

    /// Every row then every chip, in display order.
    static func items(_ sections: [Section]) -> [Item] {
        sections.flatMap { section -> [Item] in
            switch section {
            case let .context(_, _, rows), let .recent(rows): return rows.map(Item.row)
            case let .keywords(chips, _): return chips.map(Item.chip)
            }
        }
    }

    /// The rows ⌘1…⌘9 reach, in order.
    static func numberedRows(_ sections: [Section]) -> [Row] {
        Array(items(sections).compactMap { if case let .row(row) = $0 { row } else { nil } }.prefix(9))
    }

    /// The highlight after ↑ (-1) or ↓ (+1). The chip row is one stop for the
    /// vertical arrows; ← and → (`horizontal`) move along it.
    static func move(_ index: Int, by delta: Int, in items: [Item], horizontal: Bool = false) -> Int {
        guard !items.isEmpty else { return 0 }
        let current = min(max(index, 0), items.count - 1)
        let chips = items.indices.filter { if case .chip = items[$0] { true } else { false } }
        if horizontal {
            guard let position = chips.firstIndex(of: current) else { return current }
            return chips[(position + delta + chips.count) % chips.count]
        }
        // Rows come first, so the chips are the last stop.
        let stops = items.indices.filter { !chips.contains($0) } + (chips.first.map { [$0] } ?? [])
        let stop = chips.contains(current) ? stops.count - 1 : stops.firstIndex(of: current) ?? 0
        return stops[(stop + delta + stops.count) % stops.count]
    }
}
