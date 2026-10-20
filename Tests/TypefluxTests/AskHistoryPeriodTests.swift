import Foundation
import Testing
@testable import Typeflux

@Suite("Ask history periods")
struct AskHistoryPeriodTests {
    @Test func mixedDatesHaveOneHeadingPerPeriodAndKeepTheirRelativeOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 0, minute: 30))!
        let date = { (day: Int, hour: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let items = [
            AskConversationSummary(id: "y1", title: "Y1", updatedAt: date(19, 14)),
            AskConversationSummary(id: "e1", title: "E1", updatedAt: date(18, 10)),
            AskConversationSummary(id: "t1", title: "T1", updatedAt: date(20, 0)),
            AskConversationSummary(id: "e2", title: "E2", updatedAt: date(17, 9)),
            AskConversationSummary(id: "y2", title: "Y2", updatedAt: date(19, 23)),
            AskConversationSummary(id: "t2", title: "T2", updatedAt: date(20, 0))
        ]

        let ordered = AskHistoryPeriod.ordered(items, now: now, calendar: calendar)
        #expect(ordered.map(\.id) == ["t1", "t2", "y1", "y2", "e1", "e2"])
        #expect(ordered.map { AskHistoryPeriod.period(for: $0.updatedAt, now: now, calendar: calendar) }
            == [.today, .today, .yesterday, .yesterday, .earlier, .earlier])
    }
}
