import Foundation
import TypefluxChat

/// Date sections and text transformations shared by the mobile views and their tests.
enum ChatHistorySection: Int, CaseIterable, Identifiable {
    case today, yesterday, earlier
    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .earlier: "Earlier"
        }
    }
}

enum ChatPresentation {
    static func matches(_ item: ChatConversationSummary, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || item.title.localizedStandardContains(query)
    }

    static func runTitle(_ run: ChatRun) -> String {
        switch run.status {
        case "failed": "Failed"
        case "cancelled": "Stopped"
        case "completed": "Completed"
        default: run.requiresDesktop ? "Waiting for Mac" : "Running"
        }
    }

    static func historySection(for date: Date, now: Date = Date(),
                               calendar: Calendar = .current) -> ChatHistorySection {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }

    static func history(_ items: [ChatConversationSummary], matching query: String,
                        section: ChatHistorySection, now: Date = Date(),
                        calendar: Calendar = .current) -> [ChatConversationSummary] {
        items.filter {
            historySection(for: $0.updatedAt, now: now, calendar: calendar) == section &&
                matches($0, query: query)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func quote(_ text: String, into draft: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var excerpt = lines.prefix(6).map { "> " + $0 }.joined(separator: "\n")
        if lines.count > 6 {
            excerpt += "\n> …"
        }
        let prefix = draft.trimmingCharacters(in: .newlines)
        return (prefix.isEmpty ? "" : prefix + "\n\n") + excerpt + "\n\n"
    }
}

extension ChatModel {
    var mobileDisplayName: String {
        guard let multiplier = pricing?["multiplier"],
              let value = Decimal(string: multiplier, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
            return name
        }
        return "\(name) · \(multiplier)× credits"
    }
}
