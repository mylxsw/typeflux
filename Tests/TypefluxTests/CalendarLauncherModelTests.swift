import AppKit
import Testing
@testable import Typeflux

@Suite("Calendar launcher interaction", .serialized, .exclusiveUIState)
@MainActor
struct CalendarLauncherModelTests {
    func model(provider: FakeCalendarEventProvider = .init()) -> CalendarLauncherModel {
        CalendarLauncherModel(
            provider: provider,
            dates: CalendarFixtures.dates,
            now: { CalendarFixtures.date().addingTimeInterval(10 * 3600) }
        )
    }

    func activate(_ model: CalendarLauncherModel, text: String = "", options: [String: String] = [:]) async throws {
        model.activate(text: text, options: options, language: .simplifiedChinese)
        try await settle(model)
    }

    func settle(_ model: CalendarLauncherModel) async throws {
        for _ in 0 ..< 200 where model.loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.loading)
    }

    @Test func `navigation date copy and escape layers`() async throws {
        let model = model()
        defer { model.close() }
        try await activate(model)
        #expect(model.selected == CalendarFixtures.date())
        #expect(model.info.week == 42)
        #expect(model.handle(.right, inputEmpty: true) == .clearInput)
        #expect(model.selected == CalendarFixtures.date(2026, 10, 15))
        _ = model.handle(.left, inputEmpty: true)
        #expect(model.selected == CalendarFixtures.date())
        _ = model.handle(.up, inputEmpty: true)
        #expect(model.selected == CalendarFixtures.date(2026, 10, 7))
        _ = model.handle(.down, inputEmpty: true)
        #expect(model.selected == CalendarFixtures.date())
        #expect(model.handle(.left, inputEmpty: false) == .unhandled)
        #expect(model.handle(.right, inputEmpty: false) == .unhandled)
        #expect(model.handle(.commandC, inputEmpty: true) == .copy(model.copiedDate))
        #expect(model.handle(.optionEnter, inputEmpty: true) == .insert(model.copiedDate))
        #expect(model.handle(.commandN, inputEmpty: true) == .open(model.selected, event: nil, join: false))
        #expect(model.handle(.commandR, inputEmpty: true) == .unhandled)
        #expect(model.handle(.commandEnter, inputEmpty: true) == .handled)
        #expect(model.untilEvent(CalendarFixtures.events[1]) == L("calendar.startsHours", 4, 0))
        var future = CalendarFixtures.events[1]
        future.start = model.now().addingTimeInterval(120)
        #expect(model.untilEvent(future) == L("calendar.starts", 2))
        future.start = model.now().addingTimeInterval(2 * 86400)
        #expect(model.untilEvent(future) == L("calendar.startsDays", 2))
        model.update("2026-01-31")
        _ = model.handle(.commandRight, inputEmpty: false)
        #expect(model.selected == CalendarFixtures.date(2026, 2, 28))
        _ = model.handle(.commandLeft, inputEmpty: true)
        #expect(model.selected == CalendarFixtures.date(2026, 1, 28))
        _ = model.handle(.commandT, inputEmpty: false)
        model.update("")
        #expect(model.selected == model.today)
        #expect(model.handle(.escape, inputEmpty: false) == .clearInput)
        #expect(model.handle(.escape, inputEmpty: true) == .unhandled)
    }

    @Test func `event focus starts with the next event and actions use it`() async throws {
        let model = model()
        defer { model.close() }
        try await activate(model)
        #expect(model.events.count == 3 && model.sources.count == 2)
        _ = model.handle(.tab, inputEmpty: true)
        #expect(model.chosenEvent?.id == "review")
        #expect(model.handle(.enter, inputEmpty: true) == .open(
            model.selected,
            event: CalendarFixtures.events[1],
            join: true
        ))
        #expect(model.handle(.commandO, inputEmpty: true) == .open(
            model.selected,
            event: CalendarFixtures.events[1],
            join: false
        ))
        #expect(model.handle(.right, inputEmpty: true) == .unhandled)
        _ = model.handle(.up, inputEmpty: true)
        #expect(model.chosenEvent?.id == "past")
        _ = model.handle(.down, inputEmpty: true)
        #expect(model.chosenEvent?.id == "review")
        #expect(model.handle(.commandC, inputEmpty: true) == .copy(CalendarFixtures.events[1].copied(
            dates: model.dates, preferences: model.preferences, locale: model.locale
        )))
        #expect(model.handle(.escape, inputEmpty: false) == .handled)
        #expect(!model.eventFocus)
        model.selectEvent("personal")
        #expect(model.chosenEvent?.id == "personal")
        model.selectEvent("missing")
        #expect(model.chosenEvent?.id == "personal")
        _ = model.handle(.shiftTab, inputEmpty: true)
        #expect(!model.eventFocus)
    }

    @Test func `range year and search modes`() async throws {
        let model = model()
        defer { model.close() }
        try await activate(model, text: "今天到12-31")
        #expect(model.interval?.days == 78)
        #expect(model.handle(.enter, inputEmpty: false) == .copy(L("calendar.days", 78)))
        #expect(model.handle(.commandC, inputEmpty: false) == .copy(L("calendar.days", 78)))
        model.update("2027")
        _ = model.handle(.right, inputEmpty: false)
        #expect(model.dates.calendar.component(.month, from: model.selected) == 2)
        _ = model.handle(.down, inputEmpty: false)
        #expect(model.query == .year(2027))
        _ = model.handle(.up, inputEmpty: false)
        _ = model.handle(.left, inputEmpty: false)
        #expect(model.query == .year(2027))
        #expect(model.handle(.enter, inputEmpty: false) == .clearInput)
        model.showYear()
        #expect(model.query == .year(2027))
        model.update("review")
        try await settle(model)
        #expect(model.searchEvents.map(\.id) == ["review"])
        #expect(model.handle(.enter, inputEmpty: false) == .handled)
        #expect(model.handle(.commandC, inputEmpty: false) == .handled)
        _ = model.handle(.down, inputEmpty: false)
        #expect(model.chosenEvent?.id == "review")
        #expect(model.handle(.tab, inputEmpty: false) == .clearInput)
        #expect(model.selected == CalendarFixtures.date())
        model.update("no matches")
        try await settle(model)
        #expect(model.searchEvents.isEmpty)
        _ = model.handle(.up, inputEmpty: false)
        #expect(model.chosenEvent == nil)
        model.update("2-30")
        #expect(model.query == .invalid)
    }

    @Test func `permission is explicit and denial does not break dates`() async throws {
        let provider = FakeCalendarEventProvider(access: .unknown)
        let model = model(provider: provider)
        defer { model.close() }
        try await activate(model)
        #expect(await provider.requests == 0)
        #expect(model.access == .unknown && model.dayEvents.isEmpty)
        await model.requestAccess()
        try await settle(model)
        #expect(await provider.requests == 1)
        #expect(model.access == .allowed && model.dayEvents.count == 3)
        let denied = self.model(provider: .init(access: .denied))
        defer { denied.close() }
        try await activate(denied)
        #expect(denied.access == .denied)
        denied.update("春节")
        #expect(denied.selected == CalendarFixtures.date(2027, 2, 6))
        await denied.requestAccess()
        #expect(denied.access == .denied)
        await provider.setFailure()
        await model.requestAccess()
        #expect(model.error != nil && !model.requesting)
    }

    @Test func `filters invalidation and closing discard stale reads`() async throws {
        let provider = FakeCalendarEventProvider()
        let model = model(provider: provider)
        defer { model.close() }
        try await activate(model, options: ["calendar.calendars": "work"])
        #expect(model.events.count == 2)
        model.selectEvent("review")
        await provider.setEvents([])
        model.refresh(invalidate: true)
        try await settle(model)
        #expect(model.events.isEmpty && model.chosenEvent == nil && !model.eventFocus)
        #expect(await provider.invalidations == 2)
        #expect(model.handle(.tab, inputEmpty: true) == .handled)
        await provider.setEvents(CalendarFixtures.events)
        await provider.setDelay()
        model.update("review")
        model.update("2027-02-07")
        try await settle(model)
        #expect(model.events.isEmpty)
        model.update("today")
        model.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.events.isEmpty && !model.loading)
        try await activate(model, options: ["calendar.events": "false"])
        #expect(model.events.isEmpty && !model.loading && !model.preferences.showsEvents)
    }

    @Test func `hiding events preserves the selected day and search mode`() async throws {
        let model = model()
        defer { model.close() }
        try await activate(model)
        model.select(CalendarFixtures.date(2027, 2, 6))
        model.updatePreferences(options: ["calendar.events": "false"], language: .simplifiedChinese)
        #expect(model.selected == CalendarFixtures.date(2027, 2, 6))
        #expect(!model.preferences.showsEvents && model.events.isEmpty && !model.eventFocus)
        model.update("review")
        #expect(model.query == .search("review") && !model.loading)
        model.updatePreferences(options: [:], language: .simplifiedChinese)
        try await settle(model)
        #expect(model.preferences.showsEvents && model.searchEvents.count == 1)
    }

    @Test func `today button state and relative day tag follow the selection`() async throws {
        let model = model()
        defer { model.close() }
        try await activate(model)
        #expect(model.isAtToday)
        #expect(model.relativeDay == L("calendar.today"))
        _ = model.handle(.right, inputEmpty: true)
        #expect(!model.isAtToday)
        #expect(model.relativeDay == L("calendar.after", 1))
        model.select(CalendarFixtures.date(2026, 10, 9))
        #expect(model.relativeDay == L("calendar.before", 5))
        #expect(model.handle(.commandT, inputEmpty: true) == .clearInput)
        #expect(model.isAtToday)
        model.update("2027")
        #expect(!model.isAtToday)
        model.update("评审")
        #expect(!model.isAtToday)
        _ = model.handle(.commandT, inputEmpty: false)
        #expect(model.isAtToday && model.selected == model.today)
    }
}
