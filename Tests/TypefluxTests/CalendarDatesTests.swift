import Foundation
import Testing
@testable import Typeflux

enum CalendarFixtures {
    static var dates: CalendarDates {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return CalendarDates(calendar: calendar)
    }

    static func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 14) -> Date {
        dates.date(year, month, day)!
    }

    static let source = CalendarSource(id: "work", title: "Work", color: "4088FF")
    static var events: [CalendarEvent] {
        let today = date()
        return [
            CalendarEvent(
                id: "past",
                externalID: "external/past",
                title: "Standup",
                start: today.addingTimeInterval(9 * 3600),
                end: today.addingTimeInterval(9.5 * 3600),
                calendar: source
            ),
            CalendarEvent(
                id: "review",
                externalID: "external/review",
                title: "Calendar review",
                start: today.addingTimeInterval(14 * 3600),
                end: today.addingTimeInterval(15 * 3600),
                location: "Shanghai · Room 3F-B",
                notes: "Agenda: calendar design",
                url: URL(string: "https://meet.google.com/abc-defg-hij"),
                calendar: source
            ),
            CalendarEvent(
                id: "personal",
                externalID: nil,
                title: "Badminton",
                start: today.addingTimeInterval(19.5 * 3600),
                end: today.addingTimeInterval(21 * 3600),
                location: "Sports center",
                calendar: .init(id: "personal", title: "Personal", color: "22C55E")
            )
        ]
    }
}

@Suite("Calendar civil dates and festivals")
struct CalendarDatesTests {
    let dates = CalendarFixtures.dates

    @Test func `validates dates and clamps months`() {
        #expect(dates.date(2026, 2, 29) == nil)
        #expect(dates.date(2024, 2, 29) != nil)
        #expect(dates.date(2026, 2, 30) == nil)
        #expect(dates.date(2026, 13, 1) == nil)
        #expect(dates.date(1900, 1, 1) == nil)
        #expect(dates.date(2100, 1, 1) == nil)
        #expect(dates.key(dates.adding(1, .month, to: CalendarFixtures.date(2026, 1, 31))) == "2026-02-28")
        #expect(dates.key(dates.adding(1, to: CalendarFixtures.date(2026, 12, 31))) == "2027-01-01")
    }

    @Test func `fixed grid honors the system week start`() {
        let grid = dates.grid(CalendarFixtures.date())
        #expect(grid.count == 42)
        #expect(dates.key(grid[0]) == "2026-09-28")
        #expect(dates.key(grid[41]) == "2026-11-08")
        var sunday = dates
        sunday.calendar.firstWeekday = 1
        #expect(sunday.key(sunday.grid(CalendarFixtures.date())[0]) == "2026-09-27")
    }

    @Test func `day intervals remain civil across daylight saving`() throws {
        var calendar = dates.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let local = CalendarDates(calendar: calendar)
        let first = try #require(local.date(2026, 3, 8)), last = try #require(local.date(2026, 3, 9))
        #expect(last.timeIntervalSince(first) == 23 * 3600)
        #expect(local.days(from: first, to: last) == 1)
    }

    @Test(arguments: [(2026, 2, 17, "春节"), (2027, 2, 6, "春节"), (2026, 6, 19, "端午节"),
                      (2026, 9, 25, "中秋节"), (2025, 1, 28, "除夕"), (2026, 2, 16, "除夕"),
                      (2026, 5, 10, "母亲节"), (2026, 6, 21, "父亲节"), (2026, 12, 25, "圣诞节")])
    func `known festivals`(_ year: Int, _ month: Int, _ day: Int, _ name: String) {
        #expect(CalendarDayInfo(CalendarFixtures.date(year, month, day), dates: dates).festival == name)
    }

    @Test func `lunar week and ordinal`() {
        let info = CalendarDayInfo(CalendarFixtures.date(), dates: dates)
        #expect(info.lunar == "九月初五")
        #expect(info.lunarDay == "初五")
        #expect(info.zodiac == "丙午年 · 马年")
        #expect(info.week == 42 && info.ordinal == 287)
        #expect(CalendarDayInfo(CalendarFixtures.date(2026, 10, 10), dates: dates).lunarDay == "九月")
        #expect(
            CalendarDayInfo(CalendarFixtures.date(2025, 8, 28), dates: dates).festival != "七夕",
            "Leap months do not repeat festivals"
        )
    }

    @Test(arguments: [(2020, 4), (2021, 4), (2022, 5), (2023, 5), (2024, 4), (2025, 4),
                      (2026, 5), (2027, 5), (2028, 4), (2029, 4), (2030, 5)])
    func `qingming in each year`(_ year: Int, _ day: Int) {
        #expect(SolarTerms.date(year: year, index: 6, dates: dates) == CalendarFixtures.date(year, 4, day))
    }

    @Test func `solstices and equinoxes`() throws {
        for (index, month, day) in [(5, 3, 20), (11, 6, 21), (17, 9, 23), (23, 12, 22)] {
            #expect(SolarTerms.date(year: 2026, index: index, dates: dates) == CalendarFixtures.date(2026, month, day))
        }
        #expect(SolarTerms.date(year: 2026, index: -1, dates: dates) == nil)
        #expect(SolarTerms.date(year: 2026, index: 24, dates: dates) == nil)
        for year in [1901, 1950, 1999, 2099] {
            let value = try #require(SolarTerms.date(year: year, index: 23, dates: dates))
            #expect(dates.calendar.component(.year, from: value) == year)
            #expect(dates.calendar.component(.month, from: value) == 12)
        }
    }
}

@Suite("Calendar holiday schedule")
struct HolidayScheduleTests {
    let dates = CalendarFixtures.dates
    let schedule = HolidaySchedule.bundled

    @Test func `bundled official holidays and workdays`() {
        #expect(schedule.years["2026"]?.holidays.count == 7)
        #expect(schedule.years["2026"]?.workdays.count == 6)
        let holiday = schedule.status(on: CalendarFixtures.date(2026, 10, 3), dates: dates)
        #expect(holiday?.working == false && holiday?.day == 3 && holiday?.total == 7)
        #expect(schedule.isWorking(CalendarFixtures.date(2026, 10, 10), dates: dates))
        #expect(!schedule.isWorking(CalendarFixtures.date(2026, 10, 1), dates: dates))
        #expect(!schedule.isWorking(CalendarFixtures.date(2026, 10, 11), dates: dates))
        #expect(schedule.isWorking(CalendarFixtures.date(2026, 10, 12), dates: dates))
        #expect(schedule.status(on: CalendarFixtures.date(2026, 2, 23), dates: dates)?.day == 9)
    }

    @Test func `ranges include both endpoints and handle reversal`() {
        let start = CalendarFixtures.date(2026, 10, 1), end = CalendarFixtures.date(2026, 10, 10)
        let interval = schedule.interval(start, end, dates: dates)
        #expect(interval.days == 9 && interval.inclusive == 10 && interval.working == 3 && interval.resting == 7)
        #expect(schedule.interval(end, start, dates: dates) == interval)
        #expect(schedule.interval(start, start, dates: dates).inclusive == 1)
        let example = schedule.interval(CalendarFixtures.date(), CalendarFixtures.date(2026, 12, 31), dates: dates)
        #expect(example.days == 78 && example.working == 57)
    }

    @Test func `unknown years and disabled holidays use weekends`() {
        let unknown = schedule.interval(
            CalendarFixtures.date(2027, 1, 1),
            CalendarFixtures.date(2027, 1, 3),
            dates: dates
        )
        #expect(unknown.estimatedYears == [2027] && unknown.working == 1)
        let disabled = schedule.interval(
            CalendarFixtures.date(2026, 10, 1),
            CalendarFixtures.date(2026, 10, 10),
            dates: dates,
            enabled: false
        )
        #expect(disabled.working == 7 && disabled.estimatedYears.isEmpty)
        let crossing = schedule.interval(
            CalendarFixtures.date(2026, 12, 31),
            CalendarFixtures.date(2027, 1, 1),
            dates: dates
        )
        #expect(crossing.estimatedYears == [2027])
        #expect(schedule.parse("invalid", dates: dates) == nil)
        #expect(schedule.parse("2026-02-30", dates: dates) == nil)
        #expect(schedule.parse("2026-x-10-14", dates: dates) == nil)
        #expect(schedule.nextHoliday(after: CalendarFixtures.date(2026, 6, 1), dates: dates)?.0 == CalendarFixtures
            .date(
                2026,
                6,
                19
            ))
        #expect(schedule.nextHoliday(after: CalendarFixtures.date(2027, 1, 1), dates: dates) == nil)
    }
}
