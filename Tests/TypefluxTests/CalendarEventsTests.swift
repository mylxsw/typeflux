import Foundation
import Testing
@testable import Typeflux

actor FakeCalendarEventProvider: CalendarEventProviding {
    var permission: CalendarAccess
    var granted: CalendarAccess
    var snapshots: [CalendarEvent]
    var requests = 0
    var invalidations = 0
    var fail = false
    var delay: Duration = .zero

    init(access: CalendarAccess = .allowed, events: [CalendarEvent] = CalendarFixtures.events) {
        permission = access
        granted = access == .denied ? .denied : .allowed
        snapshots = events
    }

    func access() -> CalendarAccess {
        permission
    }

    func sources() -> [CalendarSource] {
        Array(Set(snapshots.map(\.calendar.id))).compactMap { id in
            snapshots.first { $0.calendar.id == id }?.calendar
        }
    }

    func requestAccess() throws -> CalendarAccess {
        requests += 1
        if fail {
            throw NSError(domain: "CalendarTests", code: 1)
        }
        permission = granted
        return granted
    }

    func events(from start: Date, to end: Date, calendars: Set<String>) async -> [CalendarEvent] {
        let result = snapshots
            .filter { $0.start < end && $0.end > start && (calendars.isEmpty || calendars.contains($0.calendar.id)) }
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        return result
    }

    func invalidate() {
        invalidations += 1
    }

    func setEvents(_ events: [CalendarEvent]) {
        snapshots = events
    }

    func setFailure() {
        fail = true
    }

    func setDelay() {
        delay = .milliseconds(30)
    }
}

@Suite("Calendar event values and meeting links")
struct CalendarEventsTests {
    @Test func `links are detected only on supported hosts`() {
        for host in MeetingLinkDetector.domains + ["us02web.zoom.us"] {
            let text = "Join: https://\(host)/room?id=123."
            #expect(MeetingLinkDetector.find(in: [text])?.host == host)
        }
        for link in [
            "https://zoom.us.evil.example/room",
            "https://fakezoom.us/room",
            "https://zoom.us@evil.example/room",
            "https://user@zoom.us/room",
            "javascript:alert(1)",
            "file:///tmp/zoom.us",
            "not a link"
        ] {
            #expect(MeetingLinkDetector.find(in: [link]) == nil)
        }
        #expect(MeetingLinkDetector.find(in: ["hello", "notes (https://meet.google.com/abc-defg-hij)"])?.absoluteString
            == "https://meet.google.com/abc-defg-hij")
    }

    @Test func `all day and cross day occurrences have exclusive end dates`() {
        let dates = CalendarFixtures.dates, today = CalendarFixtures.date()
        var event = CalendarFixtures.events[0]
        event.start = dates.adding(-1, to: today).addingTimeInterval(23 * 3600)
        event.end = today.addingTimeInterval(3600)
        #expect(event.occurs(on: today, dates: dates))
        event.start = today
        event.end = dates.adding(1, to: today)
        event.allDay = true
        #expect(event.occurs(on: today, dates: dates))
        #expect(!event.occurs(on: dates.adding(1, to: today), dates: dates))
        event.end = event.start
        #expect(event.occurs(on: today, dates: dates))
        #expect(!event.occurs(on: dates.adding(-1, to: today), dates: dates))
        #expect(CalendarEvent.sorted([CalendarFixtures.events[2], event, CalendarFixtures.events[1]])[0].allDay)
        #expect(CalendarFixtures.events[1].matches("REVIEW"))
        #expect(CalendarFixtures.events[1].matches("shanghai"))
        #expect(CalendarFixtures.events[1].matches("work"))
        #expect(!CalendarFixtures.events[1].matches("unmatched"))
    }

    @Test func `event links escape identifiers and fallback to the day`() {
        let event = CalendarFixtures.events[1]
        #expect(CalendarLinks.event(event).absoluteString.contains("external%2Freview"))
        #expect(CalendarLinks.day(event.start).scheme == "ical")
        #expect(CalendarLinks.event(CalendarFixtures.events[2]) == CalendarLinks.day(CalendarFixtures.events[2].start))
        var missing = event
        missing.externalID = ""
        #expect(CalendarLinks.event(missing) == CalendarLinks.day(missing.start))
        #expect(event.meeting?.host == "meet.google.com")
    }

    @Test func `preferences follow language and region and copy formats`() {
        #expect(CalendarPreferences(language: .simplifiedChinese, region: "US").showsLunar)
        #expect(CalendarPreferences(language: .traditionalChinese, region: "US").showsHolidays)
        #expect(CalendarPreferences(language: .english, region: "CN").showsLunar)
        #expect(!CalendarPreferences(language: .english, region: "US").showsHolidays)
        let custom = CalendarPreferences(
            options: ["calendar.lunar": "false", "calendar.holidays": "false", "calendar.weeks": "true",
                      "calendar.events": "false", "calendar.calendars": "work,personal"],
            language: .simplifiedChinese
        )
        #expect(!custom.showsLunar && !custom.showsHolidays && custom.showsWeeks && !custom.showsEvents)
        #expect(custom.calendars == ["work", "personal"])
        let dates = CalendarFixtures.dates, day = CalendarFixtures.date(), locale = Locale(identifier: "en_US")
        var preferences = CalendarPreferences(options: ["calendar.copyFormat": "iso"])
        #expect(preferences.copiedDate(day, dates: dates, locale: locale) == "2026-10-14")
        #expect(CalendarFixtures.events[1].copied(dates: dates, preferences: preferences, locale: locale)
            .contains("2026-10-14"))
        preferences.copyFormat = "short"
        #expect(preferences.copiedDate(day, dates: dates, locale: locale).contains("Oct"))
        preferences.copyFormat = "system"
        #expect(!preferences.copiedDate(day, dates: dates, locale: locale).isEmpty)
        preferences.copyFormat = "full"
        #expect(preferences.copiedDate(day, dates: dates, locale: locale).contains("2026"))
        var allDay = CalendarFixtures.events[0]
        allDay.allDay = true
        #expect(!allDay.copied(dates: dates, preferences: preferences, locale: locale).contains("–"))
    }

    @Test func `default selection only excludes duplicate holiday subscriptions`() {
        let sources = [
            CalendarFixtures.source,
            CalendarSource(id: "holidays", title: "Holidays", color: "00FF00", holiday: true),
            CalendarSource(id: "vacation", title: "My Holiday Plans", color: "00FF00")
        ]
        let chinese = CalendarPreferences(language: .simplifiedChinese)
        #expect(chinese.includedCalendars(sources) == ["work", "vacation"])
        let english = CalendarPreferences(language: .english, region: "US")
        #expect(english.includedCalendars(sources) == ["work", "vacation", "holidays"])
        #expect(chinese.includedCalendars([]) == ["none"])
        let custom = CalendarPreferences(options: ["calendar.calendars": "holidays"], language: .simplifiedChinese)
        #expect(custom.includedCalendars(sources) == ["holidays"])
    }
}
