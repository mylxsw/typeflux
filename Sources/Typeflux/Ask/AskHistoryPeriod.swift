import Foundation

enum AskHistoryPeriod: Int, CaseIterable {
    case today, yesterday, earlier

    var titleKey: String {
        switch self {
        case .today: "ask.today"
        case .yesterday: "ask.yesterday"
        case .earlier: "ask.earlier"
        }
    }

    static func period(for date: Date, now: Date, calendar: Calendar) -> Self {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }

    /// Keep each period's existing row order while making its heading appear only once.
    static func ordered(_ items: [AskConversationSummary], now: Date, calendar: Calendar) -> [AskConversationSummary] {
        var buckets = Array(repeating: [AskConversationSummary](), count: allCases.count)
        for item in items {
            buckets[period(for: item.updatedAt, now: now, calendar: calendar).rawValue].append(item)
        }
        return buckets.flatMap { $0 }
    }
}

/// The sidebar's two sections (GUL-464): tasks first, a few at a time, then chats by
/// period. The kind is read from where a row sits, so the sidebar needs no filters.
struct AskHistorySections: Equatable {
    static let taskLimit = 5

    var tasks: [AskConversationSummary]
    /// Tasks beyond the limit while the section is not expanded.
    var hiddenTasks: Int
    var chats: [AskConversationSummary]

    /// The selected task always stays visible, even past the limit.
    static func make(_ items: [AskConversationSummary], expanded: Bool, selectedId: String?,
                     now: Date, calendar: Calendar, limit: Int = taskLimit) -> Self {
        let ordered = AskHistoryPeriod.ordered(items, now: now, calendar: calendar)
        let tasks = ordered.filter { $0.resolvedKind == .work }
        let chats = ordered.filter { $0.resolvedKind != .work }
        guard !expanded, tasks.count > limit else { return Self(tasks: tasks, hiddenTasks: 0, chats: chats) }
        var shown = Array(tasks.prefix(limit))
        if let selectedId, !shown.contains(where: { $0.id == selectedId }),
           let selected = tasks.first(where: { $0.id == selectedId }) {
            shown.append(selected)
        }
        return Self(tasks: shown, hiddenTasks: tasks.count - shown.count, chats: chats)
    }
}
