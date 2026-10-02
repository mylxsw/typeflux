import Foundation

/// A command the ⌘K palette can run without leaving the keyboard.
enum AskPaletteAction: String, CaseIterable, Equatable {
    case newConversation
    case attachScreenshot
    case toggleSidebar
    case usage

    var titleKey: String {
        switch self {
        case .newConversation: return "ask.new"
        case .attachScreenshot: return "ask.screenshot"
        case .toggleSidebar: return "ask.sidebar.toggle"
        case .usage: return "ask.usage.title"
        }
    }

    var systemImage: String {
        switch self {
        case .newConversation: return "square.and.pencil"
        case .attachScreenshot: return "camera.viewfinder"
        case .toggleSidebar: return "sidebar.left"
        case .usage: return "chart.bar.xaxis"
        }
    }

    /// The key equivalent shown at the trailing edge of the row, if any.
    var shortcut: String? {
        switch self {
        case .newConversation: return "⌘N"
        case .toggleSidebar: return "⌃⌘S"
        default: return nil
        }
    }
}

/// One row of the palette: an action or a conversation to open.
enum AskPaletteRow: Equatable, Identifiable {
    case action(AskPaletteAction)
    case conversation(AskConversationSummary)

    var id: String {
        switch self {
        case let .action(action): return "action:" + action.rawValue
        case let .conversation(item): return "conversation:" + item.id
        }
    }
}

/// What the palette lists for a query, and which row the keyboard has
/// highlighted. Pure so the arrow-key and Return behaviour can be tested
/// without a window.
struct AskPaletteState: Equatable {
    var actions: [AskPaletteRow]
    var conversations: [AskPaletteRow]
    /// Index into `rows`; nil when there is nothing to highlight.
    var highlighted: Int?

    var rows: [AskPaletteRow] { actions + conversations }

    var highlightedRow: AskPaletteRow? { highlighted.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// Actions whose title matches, then conversations whose title matches.
    /// `available` lists the actions that make sense in the current window.
    static func make(query: String, conversations: [AskConversationSummary],
                     available: [AskPaletteAction] = AskPaletteAction.allCases,
                     title: (AskPaletteAction) -> String = { L($0.titleKey) }) -> AskPaletteState {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = available
            .filter { trimmed.isEmpty || title($0).localizedCaseInsensitiveContains(trimmed) }
            .map(AskPaletteRow.action)
        let matches = AskPresentation.filterHistory(conversations, query: trimmed).map(AskPaletteRow.conversation)
        let rows = actions.count + matches.count
        // A typed query lands on the first conversation: that is what Return
        // most often means. With nothing typed the first action leads.
        let first: Int? = rows == 0 ? nil : (!trimmed.isEmpty && !matches.isEmpty ? actions.count : 0)
        return AskPaletteState(actions: actions, conversations: matches, highlighted: first)
    }

    /// Moves the highlight by `delta` rows, wrapping at both ends.
    mutating func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { highlighted = nil; return }
        let current = highlighted ?? (delta > 0 ? -1 : count)
        highlighted = ((current + delta) % count + count) % count
    }
}
