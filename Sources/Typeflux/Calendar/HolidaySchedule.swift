import Foundation

struct HolidaySchedule: Decodable, Sendable {
    struct Holiday: Decodable, Sendable {
        var name: String
        var start: String
        var end: String
    }

    struct Year: Decodable, Sendable {
        var holidays: [Holiday]
        var workdays: [String]
    }

    struct Status: Equatable {
        var name: String
        var working: Bool
        var day: Int = 0
        var total: Int = 0
    }

    struct Interval: Equatable {
        var days: Int
        var inclusive: Int
        var working: Int
        var resting: Int
        var estimatedYears: [Int]
    }

    var years: [String: Year]

    func nextHoliday(after date: Date, dates: CalendarDates) -> (Date, String)? {
        years.values.flatMap(\.holidays).compactMap { holiday -> (Date, String)? in
            guard let start = parse(holiday.start, dates: dates), start > date else { return nil }
            return (start, holiday.name)
        }.min { $0.0 < $1.0 }
    }

    static let bundled: Self = {
        guard let url = Bundle.module.url(forResource: "cn", withExtension: "json"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self(years: [:]) }
        return result
    }()

    func status(on date: Date, dates: CalendarDates) -> Status? {
        let key = dates.key(date)
        guard let year = years[String(dates.calendar.component(.year, from: date))] else { return nil }
        if year.workdays.contains(key) {
            return Status(name: "calendar.workday", working: true)
        }
        guard let holiday = year.holidays.first(where: { $0.start <= key && key <= $0.end }) else { return nil }
        let start = parse(holiday.start, dates: dates), end = parse(holiday.end, dates: dates)
        return Status(name: holiday.name, working: false,
                      day: start.map { dates.days(from: $0, to: date) + 1 } ?? 1,
                      total: start.flatMap { first in end.map { dates.days(from: first, to: $0) + 1 } } ?? 1)
    }

    func isWorking(_ date: Date, dates: CalendarDates, enabled: Bool = true) -> Bool {
        if enabled, let status = status(on: date, dates: dates) {
            return status.working
        }
        if enabled {
            return ![1, 7].contains(dates.calendar.component(.weekday, from: date))
        }
        return !dates.calendar.isDateInWeekend(date)
    }

    func interval(_ first: Date, _ last: Date, dates: CalendarDates, enabled: Bool = true) -> Interval {
        let start = min(first, last), end = max(first, last)
        let count = dates.days(from: start, to: end)
        var working = 0, unknown = Set<Int>()
        for offset in 0 ... max(0, count) {
            let date = dates.adding(offset, to: start)
            if isWorking(date, dates: dates, enabled: enabled) {
                working += 1
            }
            let year = dates.calendar.component(.year, from: date)
            if enabled, years[String(year)] == nil {
                unknown.insert(year)
            }
        }
        return Interval(days: count, inclusive: count + 1, working: working,
                        resting: count + 1 - working, estimatedYears: unknown.sorted())
    }

    func parse(_ key: String, dates: CalendarDates) -> Date? {
        let fields = key.split(separator: "-", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        return fields.count == 3 && parts.count == 3 ? dates.date(parts[0], parts[1], parts[2]) : nil
    }
}
