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
        case applications(rows: [Row])
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
    static let maximumHomeApplications = 12

    static func build(_ context: Context) -> [Section] {
        let apps = context.applications.filter { $0.kind == .application }.prefix(maximumHomeApplications).map {
            Row(id: "application." + $0.id, title: $0.name, symbol: "app", tint: .neutral,
                action: .application($0))
        }
        return apps.isEmpty ? [] : [.applications(rows: apps)]
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
            case let .context(_, _, rows), let .recent(rows), let .applications(rows): return rows.map(Item.row)
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
