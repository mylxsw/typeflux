import Foundation
import Testing
@testable import Typeflux

@Suite("Calendar input recognition")
struct CalendarQueryParserTests {
    let parser = CalendarQueryParser(today: CalendarFixtures.date(), dates: CalendarFixtures.dates)

    @Test(arguments: [("", 2026, 10, 14), ("今天", 2026, 10, 14), ("TODAY", 2026, 10, 14),
                      ("明天", 2026, 10, 15), ("后天", 2026, 10, 16), ("昨天", 2026, 10, 13),
                      ("前天", 2026, 10, 12), ("tomorrow", 2026, 10, 15), ("yesterday", 2026, 10, 13),
                      ("2027-02-07", 2027, 2, 7), ("2027/2/7", 2027, 2, 7), ("2027年2月7日", 2027, 2, 7),
                      ("12-25", 2026, 12, 25), ("12/25", 2026, 12, 25), ("12月25日", 2026, 12, 25),
                      ("+30", 2026, 11, 13), ("-7", 2026, 10, 7), ("+2w", 2026, 10, 28),
                      ("30天后", 2026, 11, 13), ("3周后", 2026, 11, 4), ("3天前", 2026, 10, 11),
                      ("下周五", 2026, 10, 23), ("下下周三", 2026, 10, 28), ("周一", 2026, 10, 19),
                      ("本周一", 2026, 10, 12), ("上周日", 2026, 10, 11), ("next fri", 2026, 10, 23),
                      ("last fri", 2026, 10, 9), ("fri", 2026, 10, 16), ("dec 25", 2026, 12, 25),
                      ("december 25 2027", 2027, 12, 25), ("春节", 2027, 2, 6), ("除夕", 2027, 2, 5),
                      ("中秋", 2027, 9, 15), ("christmas", 2026, 12, 25), ("冬至", 2026, 12, 22),
                      ("清明", 2027, 4, 5), ("国庆", 2027, 10, 1)])
    func dates(_ text: String, _ year: Int, _ month: Int, _ day: Int) {
        #expect(parser.parse(text) == .date(CalendarFixtures.date(year, month, day)))
    }

    @Test func `years months and ranges`() {
        #expect(parser.parse("2027") == .year(2027))
        #expect(parser.parse("2027年") == .year(2027))
        for text in ["2026-12", "2026/12", "2026年12月"] {
            #expect(parser.parse(text) == .month(CalendarFixtures.date(2026, 12, 1)))
        }
        #expect(parser.parse("3月") == .month(CalendarFixtures.date(2026, 3, 1)))
        #expect(parser.parse("下个月") == .month(CalendarFixtures.date(2026, 11, 1)))
        #expect(parser.parse("上个月") == .month(CalendarFixtures.date(2026, 9, 1)))
        #expect(parser.parse("this month") == .month(CalendarFixtures.date(2026, 10, 1)))
        for text in ["今天 到 12-31", "today to 12-31", "今天~12-31", "今天～12-31"] {
            #expect(parser.parse(text) == .range(CalendarFixtures.date(), CalendarFixtures.date(2026, 12, 31)))
        }
        #expect(parser.parse("10/1 10/8") == .range(
            CalendarFixtures.date(2026, 10, 1),
            CalendarFixtures.date(2026, 10, 8)
        ))
        #expect(parser.parse("今天到不存在") == .invalid)
    }

    @Test func `invalid and unrecognized input`() {
        for text in ["2-30", "2月30日", "+99999", "2026-2-29", "2027-13-1", "2026-13", "2100", "1800", "2026-02-40"] {
            #expect(parser.parse(text) == .invalid)
        }
        #expect(parser.parse("2024-02-29") == .date(CalendarFixtures.date(2024, 2, 29)))
        #expect(parser.parse(" 上海 ") == .search("上海"))
        #expect(parser.parse("review meeting") == .search("review meeting"))
        #expect(parser.parse("'") == .search("'"))
        #expect(parser.parse(String(repeating: "x", count: 1000)) == .search(String(repeating: "x", count: 256)))
    }

    @Test func `sunday and year boundaries`() {
        let sunday = CalendarQueryParser(today: CalendarFixtures.date(2026, 10, 18), dates: CalendarFixtures.dates)
        #expect(sunday.parse("下周日") == .date(CalendarFixtures.date(2026, 10, 25)))
        #expect(sunday.parse("周日") == .date(CalendarFixtures.date(2026, 10, 18)))
        let boundary = CalendarQueryParser(today: CalendarFixtures.date(2026, 12, 31), dates: CalendarFixtures.dates)
        #expect(boundary.parse("明天") == .date(CalendarFixtures.date(2027, 1, 1)))
        let festival = CalendarQueryParser(today: CalendarFixtures.date(2026, 2, 17), dates: CalendarFixtures.dates)
        #expect(festival.parse("春节") == .date(CalendarFixtures.date(2026, 2, 17)))
    }

    @Test func `relative months and festivals stay within the supported years`() {
        let first = CalendarQueryParser(today: CalendarFixtures.date(1901, 1, 1), dates: CalendarFixtures.dates)
        #expect(first.parse("last month") == .invalid)
        #expect(first.parse("上个月") == .invalid)
        let last = CalendarQueryParser(today: CalendarFixtures.date(2099, 12, 31), dates: CalendarFixtures.dates)
        for text in ["next month", "下个月", "春节", "明天", "今天到春节", "今天 春节"] {
            #expect(last.parse(text) == .invalid)
        }
    }
}
