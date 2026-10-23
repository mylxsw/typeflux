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
