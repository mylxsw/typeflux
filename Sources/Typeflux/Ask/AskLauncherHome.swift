import Foundation

/// The applications the launcher offers before anything is typed.
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
        case application(AskAppEntry)
    }

    enum Tint: Equatable {
        case accent, orange, purple, green, neutral, red
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
        case applications(rows: [Row])
        case features(rows: [Row])
        /// `teaching` indicates a fallback list without any recorded keyword use.
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
        /// Each keyword's usage count, by `AskKeyword.id`.
        var usage: [String: Double] = [:]
        var lastUsed: [String: Date] = [:]
        /// Shuffled once per session, so unused suggestions do not jump during rendering.
        var fallbackKeywordIDs: [String] = []
        var applications: [AskAppEntry] = []
        var conversations: [AskConversationSummary] = []
        var now = Date()
    }

    static let maximumChips = 6
    /// Six grid rows cover the initial viewport plus the next scroll row.
    static let iconPrefetchCount = AskApplicationGrid.columns * 6

    static func build(_ context: Context) -> [Section] {
        let apps = context.applications.filter { $0.kind == .application }.map {
            Row(id: "application." + $0.id, title: $0.name, symbol: "app", tint: .neutral,
                action: .application($0))
        }
        return apps.isEmpty ? [] : [.features(rows: featureRows), .applications(rows: apps)]
    }

    /// Fixed destinations are independent of keyword usage and custom aliases.
    static var featureRows: [Row] {
        let definitions: [(String, String, String, Tint, AskKeyword)] = [
            ("chat", "Chat", "bubble.left.and.bubble.right", .accent,
             AskKeyword(keyword: "chat", pluginID: AskOpenChatPlugin.id)),
            ("translate", L("ask.plugin.translate.title"), "character.bubble", .purple,
             AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)),
            ("screenshot", L("screenshot.title"), "camera.viewfinder", .neutral,
             AskKeyword(keyword: "jt", pluginID: AskScreenshotPlugin.id,
                        options: [ScreenshotMode.option: ScreenshotMode.region.rawValue])),
            ("recording", L("recording.title"), "record.circle", .red,
             AskKeyword(keyword: "lp", pluginID: AskScreenshotPlugin.id,
                        options: [ScreenshotMode.option: ScreenshotMode.recording.rawValue])),
            ("notes", L("ask.home.notes"), "note.text", .orange,
             AskKeyword(keyword: "notebook", pluginID: AskNotesPlugin.id,
                        options: [AskNotesPlugin.windowOption: "true"])),
            ("wordbook", L("ask.wordBook.title"), "character.book.closed", .green,
             AskKeyword(keyword: "dict", pluginID: AskTranslatePlugin.id,
                        options: [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction])),
            ("clipboard", L("ask.home.clipboard"), "doc.on.clipboard", .purple,
             AskKeyword(keyword: "clip", pluginID: AskClipboardPlugin.id))
        ]
        return definitions.map { id, title, symbol, tint, keyword in
            Row(id: "feature." + id, title: title, symbol: symbol, tint: tint, action: .keyword(keyword))
        }
    }

    // MARK: - Keywords

    /// Usage count wins, then last use. Unused keywords fill the remaining slots.
    static func chips(_ context: Context) -> (chips: [Chip], teaching: Bool) {
        let used = context.keywords.filter { (context.usage[$0.keyword.id] ?? 0) > 0 }
        let ranked = used.enumerated().sorted { lhs, rhs in
            let left = context.usage[lhs.element.keyword.id] ?? 0
            let right = context.usage[rhs.element.keyword.id] ?? 0
            if left != right { return left > right }
            let leftDate = context.lastUsed[lhs.element.keyword.id] ?? .distantPast
            let rightDate = context.lastUsed[rhs.element.keyword.id] ?? .distantPast
            return leftDate != rightDate ? leftDate > rightDate : lhs.offset < rhs.offset
        }.map(\.element)
        let usedIDs = Set(used.map { $0.keyword.id })
        let fallbackOrder = Dictionary(uniqueKeysWithValues: context.fallbackKeywordIDs.enumerated().map { ($0.element, $0.offset) })
        let unused = context.keywords.enumerated().filter { !usedIDs.contains($0.element.keyword.id) }.sorted {
            (fallbackOrder[$0.element.keyword.id] ?? $0.offset) < (fallbackOrder[$1.element.keyword.id] ?? $1.offset)
        }.map(\.element)
        return ((ranked + unused).prefix(maximumChips).map(chip), used.isEmpty)
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
            case let .context(_, _, rows), let .recent(rows), let .applications(rows), let .features(rows): return rows.map(Item.row)
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
        if items.allSatisfy({ item in
            guard case let .row(row) = item else { return false }
            if case .application = row.action { return true }
            return row.id.hasPrefix("feature.")
        }) {
            return AskApplicationGrid.move(index, delta: delta, count: items.count, horizontal: horizontal)
        }
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
