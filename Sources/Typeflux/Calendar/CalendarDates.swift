import Foundation

/// Civil-day arithmetic always uses a Gregorian calendar in the user's time zone.
struct CalendarDates: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        gregorian.firstWeekday = calendar.firstWeekday
        self.calendar = gregorian
    }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        guard (1901 ... 2099).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day),
              let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: value)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return value
    }

    func adding(_ amount: Int, _ component: Calendar.Component = .day, to date: Date) -> Date {
        calendar.date(byAdding: component, value: amount, to: date) ?? date
    }

    func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end))
            .day ?? 0
    }

    func monthStart(_ day: Date) -> Date {
        calendar.dateInterval(of: .month, for: day)?.start ?? day
    }

    func grid(_ month: Date) -> [Date] {
        let start = monthStart(month)
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0 ..< 42).map { adding($0 - offset, to: start) }
    }

    func key(_ day: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func format(_ day: Date, _ template: String, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day)
    }
}
