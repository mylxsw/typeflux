import Foundation

/// Times and days written in Chinese or English: "下午 3 点半", "9am", "15:00", "明天", "下周五", "10-25".
enum WorldClockTimeText {
    struct Time: Equatable {
        var hour: Int
        var minute: Int
        /// The text with the time taken out.
        var rest: String
    }

    /// Which day a typed time is on, read in the place the time belongs to.
    enum Day: Equatable {
        case relative(Int)
        /// `Calendar` weekday (1 is Sunday). `week` nil is the next one, today included;
        /// 0 is this week, 1 next week, weeks starting on Monday.
        case weekday(Int, week: Int?)
        case date(year: Int?, month: Int, day: Int)

        func date(today: Date, calendar: Calendar) -> Date? {
            let start = calendar.startOfDay(for: today)
            switch self {
            case let .relative(days):
                return calendar.date(byAdding: .day, value: days, to: start)
            case let .weekday(weekday, week):
                let current = calendar.component(.weekday, from: start)
                guard let week else {
                    return calendar.date(byAdding: .day, value: (weekday - current + 7) % 7, to: start)
                }
                // "下周五": the Friday of next week.
                let mondayOffset = (current + 5) % 7
                let days = 7 * week - mondayOffset + (weekday + 5) % 7
                return calendar.date(byAdding: .day, value: days, to: start)
            case let .date(year, month, day):
                var parts = DateComponents()
                parts.year = year ?? calendar.component(.year, from: start)
                parts.month = month
                parts.day = day
                guard let date = calendar.date(from: parts),
                      calendar.component(.month, from: date) == month,
                      calendar.component(.day, from: date) == day else { return nil }
                return date
            }
        }
    }

    // MARK: - Time

    // swiftlint:disable line_length
    private static let clock = regex(
        #"(上午|早上|早晨|中午|下午|傍晚|晚上|夜里|夜裡|凌晨)?\s*(\d{1,2})\s*(?:[:：](\d{2})|[点點時时]\s*(半|一刻|三刻|\d{1,2}\s*分?)?)\s*(a\.?m\.?|p\.?m\.?)?"#
    )
    // swiftlint:enable line_length
    private static let meridiem = regex(#"(?<![\d:])(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#)

    /// The first time in `text`; nil when there is none or it is not a real time ("25:00", "13pm").
    static func time(in text: String) -> Time? { // swiftlint:disable:this cyclomatic_complexity
        let range = NSRange(text.startIndex..., in: text)
        for pattern in [clock, meridiem] {
            guard let match = pattern?.firstMatch(in: text, range: range),
                  let whole = Range(match.range, in: text) else { continue }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            var hour: Int, minute = 0, period: String?, marker: String?
            if pattern === meridiem {
                guard let value = group(1).flatMap(Int.init) else { return nil }
                hour = value
                marker = group(2)
            } else {
                guard let value = group(2).flatMap(Int.init) else { return nil }
                hour = value
                period = group(1)
                marker = group(5)
                if let digits = group(3) {
                    minute = Int(digits) ?? -1
                } else if let fraction = group(4) {
                    switch fraction {
                    case "半": minute = 30
                    case "一刻": minute = 15
                    case "三刻": minute = 45
                    default: minute = Int(fraction.filter(\.isNumber)) ?? -1
                    }
                }
            }
            guard let resolved = resolve(hour: hour, minute: minute, period: period, marker: marker) else { return nil }
            var rest = text
            rest.replaceSubrange(whole, with: " ")
            return Time(hour: resolved.hour, minute: resolved.minute, rest: rest)
        }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func resolve(hour: Int, minute: Int, period: String?, marker: String?) -> (hour: Int, minute: Int)? {
        guard (0 ... 59).contains(minute) else { return nil }
        var hour = hour
        if let marker = marker?.lowercased().replacingOccurrences(of: ".", with: "") {
            guard (1 ... 12).contains(hour) else { return nil }
            if marker == "pm", hour < 12 { hour += 12 }
            if marker == "am", hour == 12 { hour = 0 }
        } else if let period {
            guard (0 ... 12).contains(hour) || (hour <= 23 && !["上午", "早上", "早晨", "凌晨"].contains(period)) else {
                return nil
            }
            switch period {
            case "下午", "傍晚", "晚上", "夜里", "夜裡": if hour < 12 { hour += 12 }
            case "中午": if hour < 6 { hour += 12 }
            default: if hour == 12 { hour = 0 }
            }
        }
        guard (0 ... 23).contains(hour) else { return nil }
        return (hour, minute)
    }

    // MARK: - Day

    private static let relativeWords: [(String, Int)] = [
        ("大后天", 3), ("大後天", 3), ("后天", 2), ("後天", 2), ("明天", 1), ("明日", 1), ("今天", 0), ("今日", 0),
        ("昨天", -1), ("tomorrow", 1), ("tmrw", 1), ("tmr", 1), ("today", 0), ("tonight", 0), ("yesterday", -1)
    ]
    private static let chineseWeekday = regex(#"(下下|下|这|這|本)?\s*(?:个|個)?\s*(?:周|週|星期|礼拜|禮拜)\s*([一二三四五六日天])"#)
    private static let englishWeekday = regex(
        #"\b(next\s+)?(mon|tue|wed|thu|fri|sat|sun)(?:day|sday|nesday|rsday|urday)?\b\.?"#
    )
    private static let fullDate = regex(#"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?"#)
    private static let monthDay = regex(#"(?<![\d:])(\d{1,2})\s*(?:[-/]|月)\s*(\d{1,2})\s*[日号號]?(?![\d:])"#)

    /// Takes the first day word or date out of `text`; today when there is none.
    static func day(in text: inout String) -> Day {
        let lower = text.lowercased()
        for (word, days) in relativeWords {
            if let range = lower.range(of: word) {
                text = String(lower[..<range.lowerBound]) + " " + String(lower[range.upperBound...])
                return .relative(days)
            }
        }
        if let (match, found) = first(chineseWeekday, in: text) {
            let weekday = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7][found(2) ?? ""] ?? 1
            let week = ["下下": 2, "下": 1, "这": 0, "這": 0, "本": 0][found(1) ?? ""]
            text.replaceSubrange(match, with: " ")
            return .weekday(weekday, week: week)
        }
        if let (match, found) = first(englishWeekday, in: text) {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            let weekday = (names.firstIndex(of: (found(2) ?? "").lowercased()) ?? 0) + 1
            text.replaceSubrange(match, with: " ")
            return .weekday(weekday, week: found(1) == nil ? nil : 1)
        }
        if let (match, found) = first(fullDate, in: text),
           let year = found(1).flatMap(Int.init), let month = found(2).flatMap(Int.init),
           let day = found(3).flatMap(Int.init) {
            text.replaceSubrange(match, with: " ")
            return .date(year: year, month: month, day: day)
        }
        if let (match, found) = first(monthDay, in: text),
           let month = found(1).flatMap(Int.init), let day = found(2).flatMap(Int.init) {
            text.replaceSubrange(match, with: " ")
            return .date(year: nil, month: month, day: day)
        }
        return .relative(0)
    }

    private static func first(_ pattern: NSRegularExpression?,
                              in text: String) -> (Range<String.Index>, (Int) -> String?)? {
        guard let match = pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return (range, { index in Range(match.range(at: index), in: text).map { String(text[$0]) } })
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
