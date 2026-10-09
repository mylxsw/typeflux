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
    enum RunNotice: Equatable {
        case stopped
        case failure(String)
    }

    static func matches(_ item: ChatConversationSummary, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || item.title.localizedStandardContains(query)
    }

    static func runTitle(_ run: ChatRun) -> String {
        switch run.status {
        case "failed": "Failed"
        case "cancelled": "Stopped"
        case "completed": "Completed"
        case "paused_credits": "Paused"
        default: run.requiresDesktop ? "Waiting for Mac" : "Running"
        }
    }

    /// The title pill's second line: "Completed · 2 steps", "Running · step 2".
    static func runStatusLine(_ run: ChatRun, steps: Int) -> String {
        let title = NSLocalizedString(runTitle(run), comment: "Run state")
        switch run.status {
        case "completed":
            guard steps > 0 else { return title }
            return title + " · " + String(format: NSLocalizedString("%d steps", comment: "Run step count"), steps)
        case "failed", "cancelled":
            return title
        case "paused_credits":
            return title + " · " + NSLocalizedString("Out of credits", comment: "Run paused for credits")
        default:
            return title + " · " + String(format: NSLocalizedString("Step %d", comment: "Activity step"), max(1, steps))
        }
    }

    static func runNotice(_ run: ChatRun) -> RunNotice? {
        // A user-requested stop is a terminal state, not a connection failure.
        if run.status == "cancelled" {
            return .stopped
        }
        if let error = run.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return .failure(error)
        }
        return run.status == "failed" ? .failure("The server could not complete this request.") : nil
    }

    static func hasHorizontalOverflow(contentWidth: CGFloat, viewportWidth: CGFloat) -> Bool {
        // Ignore initial geometry and subpoint rounding before advertising a gesture.
        contentWidth.isFinite && viewportWidth.isFinite && viewportWidth > 0 && contentWidth > viewportWidth + 1
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

    /// Sidebar time: the clock for today and yesterday, the date for older items.
    static func historyTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                            locale: Locale = .current) -> String {
        if historySection(for: date, now: now, calendar: calendar) == .earlier {
            return date.formatted(.dateTime.month(.defaultDigits).day().locale(locale))
        }
        return date.formatted(.dateTime.hour().minute().locale(locale))
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
