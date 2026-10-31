import Foundation

/// Explicit, local date syntax; unrecognized date prefixes never silently lose an alarm.
struct AppleReminderDraft: Equatable, Sendable {
    var title: String
    var due: Date?

    static func parse(_ input: String, now: Date, calendar: Calendar = .current) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.invalid }
        if let parts = captures(#"^(\d+)\s*(m|h|d|分钟|小时|天)(?:后)?\s+(.+)$"#, text) {
            guard let amount = Int(parts[0]), (1 ... 525600).contains(amount) else { throw Failure.invalid }
            let unit = parts[1].lowercased()
            let component: Calendar.Component = ["d", "天"].contains(unit) ? .day
                : ["h", "小时"].contains(unit) ? .hour : .minute
            guard let due = calendar.date(byAdding: component, value: amount, to: now) else { throw Failure.invalid }
            return try validated(parts[2], due: due, now: now)
        }
        if let parts = captures(#"^(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s+(.+)$"#, text) {
            let day = parts[0].split(separator: "-").compactMap { Int($0) }
            let due = try date(day: DateComponents(year: day[0], month: day[1], day: day[2]),
                               time: parts[1], calendar: calendar)
            return try validated(parts[2], due: due, now: now)
        }
        if let parts = captures(#"^(今天|明天|后天|today|tomorrow)\s+(\d{1,2}:\d{2})\s+(.+)$"#, text) {
            let offset = ["明天", "tomorrow"].contains(parts[0].lowercased()) ? 1 : parts[0] == "后天" ? 2 : 0
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { throw Failure.invalid }
            return try validated(parts[2], due: date(day: calendar.dateComponents([.year, .month, .day], from: day),
                                                   time: parts[1], calendar: calendar), now: now)
        }
        if let parts = captures(#"^(\d{1,2}:\d{2})\s+(.+)$"#, text) {
            var due = try date(day: calendar.dateComponents([.year, .month, .day], from: now),
                               time: parts[0], calendar: calendar)
            if due <= now {
                guard let next = calendar.date(byAdding: .day, value: 1, to: due) else { throw Failure.invalid }
                due = next
            }
            return try validated(parts[1], due: due, now: now)
        }
        if captures(#"^(\d{4}-|\d{1,2}:|今天|明天|后天|today\b|tomorrow\b|\d+\s*(?:m\b|h\b|d\b|分钟|小时|天))"#, text) != nil {
            throw Failure.invalid
        }
        return .init(title: text, due: nil)
    }

    private static func validated(_ title: String, due: Date, now: Date) throws -> Self {
        guard due > now else { throw Failure.past }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.invalid }
        return .init(title: title, due: due)
    }

    private static func date(day: DateComponents, time: String, calendar: Calendar) throws -> Date {
        let clock = time.split(separator: ":").compactMap { Int($0) }
        guard clock.count == 2, (0 ... 23).contains(clock[0]), (0 ... 59).contains(clock[1]) else { throw Failure.invalid }
        var parts = day
        parts.hour = clock[0]; parts.minute = clock[1]; parts.second = 0
        guard let value = calendar.date(from: parts) else { throw Failure.invalid }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: value)
        guard actual.year == parts.year, actual.month == parts.month, actual.day == parts.day,
              actual.hour == parts.hour, actual.minute == parts.minute else { throw Failure.invalid }
        return value
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    enum Failure: Error {
        case invalid, past
    }
}
