import Foundation

enum CalendarQuery: Equatable, Sendable {
    case date(Date), month(Date), year(Int), range(Date, Date), search(String), invalid
}

/// Deterministic parsing; all relative expressions are anchored to the supplied day.
struct CalendarQueryParser {
    var today: Date
    var dates: CalendarDates = .init()

    // Recognizes the ordered date grammar before falling back to event search.
    // swiftlint:disable:next cyclomatic_complexity
    func parse(_ input: String) -> CalendarQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty {
            return .date(dates.calendar.startOfDay(for: today))
        }
        for separator in [" 到 ", "到", " ~ ", "~", "～", " to "] {
            let pair = text.components(separatedBy: separator)
            if pair.count == 2 {
                guard let first = day(pair[0]), let last = day(pair[1]), supported(first), supported(last)
                else { return .invalid }
                return .range(first, last)
            }
        }
        let words = text.split(separator: " ").map(String.init)
        if words.count == 2, let first = day(words[0]), let last = day(words[1]) {
            return supported(first) && supported(last) ? .range(first, last) : .invalid
        }
        if let value = day(text) {
            return supported(value) ? .date(value) : .invalid
        }
        if let match = groups("^([0-9]{4})年?$", text) {
            guard let year = Int(match[0]), (1901 ... 2099).contains(year) else { return .invalid }
            return .year(year)
        }
        let year = dates.calendar.component(.year, from: today)
        if let match = groups("^([0-9]{4})[-/年]([0-9]{1,2})月?$", text) {
            return dates.date(Int(match[0]) ?? 0, Int(match[1]) ?? 0, 1).map(CalendarQuery.month) ?? .invalid
        }
        if let match = groups("^([0-9]{1,2})月$", text) {
            return dates.date(year, Int(match[0]) ?? 0, 1).map(CalendarQuery.month) ?? .invalid
        }
        if ["下个月", "上个月", "本月", "next month", "last month", "this month"].contains(text) {
            let step = ["下个月", "next month"].contains(text) ? 1 : ["上个月", "last month"].contains(text) ? -1 : 0
            let month = dates.monthStart(dates.adding(step, .month, to: today))
            return supported(month) ? .month(month) : .invalid
        }
        // A malformed date must not become an event search.
        if text.range(of: "^[0-9]+[-/年月][0-9]|^[+-][0-9]+(?:w|d|天|周)?$", options: .regularExpression) != nil {
            return .invalid
        }
        return .search(String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)))
    }

    // Each branch describes one independently tested date expression.
    // swiftlint:disable:next cyclomatic_complexity
    private func day(_ input: String) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = dates.calendar.component(.year, from: today)
        let offsets = ["今天": 0, "今日": 0, "today": 0, "明天": 1, "tomorrow": 1, "后天": 2,
                       "昨天": -1, "yesterday": -1, "前天": -2]
        if let offset = offsets[text] {
            return dates.calendar.startOfDay(for: dates.adding(offset, to: today))
        }
        if let match = groups("^([0-9]{4})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})日?$", text) {
            return dates.date(Int(match[0]) ?? 0, Int(match[1]) ?? 0, Int(match[2]) ?? 0)
        }
        if let match = groups("^([0-9]{1,2})[-/月]([0-9]{1,2})日?$", text) {
            return dates.date(year, Int(match[0]) ?? 0, Int(match[1]) ?? 0)
        }
        if let match = groups("^([+-][0-9]{1,5})(w|d|周|天)?$", text), let amount = Int(match[0]) {
            return relative(amount * (["w", "周"].contains(match[1]) ? 7 : 1))
        }
        if let match = groups("^([0-9]{1,5})(天|周)(后|前)$", text), let amount = Int(match[0]) {
            return relative(amount * (match[1] == "周" ? 7 : 1) * (match[2] == "前" ? -1 : 1))
        }
        if let match = groups("^(下下|下|本|这|上)?(?:周|星期)([一二三四五六日天])$", text) {
            let weekday = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7][match[1]] ?? 1
            let current = dates.calendar.component(.weekday, from: today)
            let mondayOffset = (current + 5) % 7
            let weeks = ["下下": 2, "下": 1, "上": -1][match[0]] ?? 0
            var offset = -mondayOffset + (weekday + 5) % 7 + weeks * 7
            if match[0].isEmpty, offset < 0 {
                offset += 7
            }
            return relative(offset)
        }
        if let match = groups("^(next |last )?(sun|mon|tue|wed|thu|fri|sat)(?:day|sday|nesday|rsday|urday)?$", text) {
            let weekday = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: match[1]) ?? 0
            let current = dates.calendar.component(.weekday, from: today) - 1
            var offset = (weekday - current + 7) % 7
            if match[0] == "next " {
                offset = -(current + 6) % 7 + (weekday + 6) % 7 + 7
            }
            if match[0] == "last " {
                offset = -(current + 6) % 7 + (weekday + 6) % 7 - 7
            }
            return relative(offset)
        }
        if let match = groups("^([a-z]+) ([0-9]{1,2})(?: ([0-9]{4}))?$", text) {
            let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            if let month = names.firstIndex(of: String(match[0].prefix(3))) {
                return dates.date(Int(match[2]) ?? year, month + 1, Int(match[1]) ?? 0)
            }
        }
        return festival(text)
    }

    private func relative(_ offset: Int) -> Date? {
        guard abs(offset) <= 36600 else { return nil }
        let result = dates.calendar.startOfDay(for: dates.adding(offset, to: today))
        return (1901 ... 2099).contains(dates.calendar.component(.year, from: result)) ? result : nil
    }

    private func supported(_ date: Date) -> Bool {
        (1901 ... 2099).contains(dates.calendar.component(.year, from: date))
    }

    private func festival(_ text: String) -> Date? {
        let aliases = ["中秋": "中秋节", "端午": "端午节", "国庆": "国庆节", "圣诞": "圣诞节", "清明": "清明",
                       "christmas": "圣诞节", "new year": "元旦", "spring festival": "春节", "chinese new year": "春节",
                       "mid autumn": "中秋节", "dragon boat": "端午节", "winter solstice": "冬至"]
        let name = aliases[text] ?? text
        let known = ["春节", "除夕", "元宵节", "龙抬头", "端午节", "七夕", "中元节", "中秋节", "重阳节", "腊八节", "小年",
                     "元旦", "国庆节", "劳动节", "圣诞节", "平安夜", "母亲节", "父亲节"] + SolarTerms.names
        guard known.contains(name) else { return nil }
        // A lunar festival occurs within this window, including leap-month years.
        for offset in 0 ... 400 {
            let candidate = dates.calendar.startOfDay(for: dates.adding(offset, to: today))
            let info = CalendarDayInfo(candidate, dates: dates)
            if info.festival == name || info.solarTerm == name {
                return candidate
            }
        }
        return nil
    }

    private func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
