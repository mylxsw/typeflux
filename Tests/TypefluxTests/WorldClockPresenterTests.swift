import Foundation
import Testing
@testable import Typeflux

@Suite("World clock rows and text", .serialized, .exclusiveUIState)
@MainActor
struct WorldClockPresenterTests {
    private func withEnglish(_ body: () throws -> Void) rethrows {
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(old) }
        try body()
    }

    private func presenter(_ preferences: WorldClockPreferences = .init(options: [WorldClockPreferences.hourFormatOption: "24"],
                                                                        localZone: WorldClockFixtures.shanghai),
                           language: AppLanguage = .english) -> WorldClockPresenter {
        WorldClockPresenter(preferences: preferences, language: language, now: WorldClockFixtures.now,
                            localZone: WorldClockFixtures.shanghai, localName: "Beijing")
    }

    private func city(_ id: String) throws -> WorldClockCity {
        try #require(WorldClockFixtures.directory.city(id: id))
    }

    @Test func `offsets durations and relative times`() {
        withEnglish {
            #expect(WorldClockFormat.utcOffset(seconds: 0) == "UTC")
            #expect(WorldClockFormat.utcOffset(seconds: 28800) == "UTC+8")
            #expect(WorldClockFormat.utcOffset(seconds: -14400) == "UTC−4")
            #expect(WorldClockFormat.utcOffset(seconds: 20700) == "UTC+5:45")
            #expect(WorldClockFormat.duration(minutes: 45) == "45 min")
            #expect(WorldClockFormat.duration(minutes: -720) == "12 h")
            #expect(WorldClockFormat.duration(minutes: 150) == "2 h 30 min")
            #expect(WorldClockFormat.difference(seconds: 0, from: "Beijing") == "Same time as Beijing")
            #expect(WorldClockFormat.difference(seconds: -43200, from: "Beijing") == "12 h behind Beijing")
            #expect(WorldClockFormat.difference(seconds: 3600, from: "Beijing") == "1 h ahead of Beijing")
            let now = WorldClockFixtures.now
            #expect(WorldClockFormat.relative(now.addingTimeInterval(20), to: now) == "Now")
            #expect(WorldClockFormat.relative(now.addingTimeInterval(9360), to: now) == "in 2 h 36 min")
            #expect(WorldClockFormat.relative(now.addingTimeInterval(-3 * 86400), to: now) == "3 days ago")
            #expect(WorldClockFormat.relative(now.addingTimeInterval(95760), to: now) == "in 1 days 2 h")
            #expect(WorldClockFormat.dayWord(delta: 2, date: now, in: WorldClockFixtures.shanghai,
                                             locale: Locale(identifier: "en")) == "Oct 22")
        }
    }

    @Test func `a row reads the difference day and daylight saving`() throws {
        try withEnglish {
            let presenter = presenter()
            let timeline = WorldClockTimeline(showing: WorldClockFixtures.now, localZone: WorldClockFixtures.shanghai)
            let newYork = presenter.row(try city("newyork"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(newYork.time == "06:24")
            #expect(newYork.day.hasPrefix("Today"))
            #expect(!newYork.differentDay)
            #expect(newYork.subtitle == "United States · 12 h behind Beijing")
            #expect(newYork.isDaylightSaving && newYork.period == .twilight)
            #expect(newYork.detail == "EDT · UTC−4 · America/New_York")
            #expect(newYork.transition?.contains("in 10 days") == true)
            #expect(newYork.transition?.contains("13 h behind Beijing") == true)
            #expect(newYork.transitionSoon)
            #expect(newYork.slots.count == WorldClockTimeline.slotCount)
            #expect(newYork.markers.contains { $0.midnight })

            let london = presenter.row(try city("london"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(london.transition?.hasPrefix("Daylight saving ends in 3 days") == true)
            #expect(london.transition?.contains("8 h behind Beijing") == true)

            let sydney = presenter.row(try city("sydney"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(sydney.time == "21:24" && sydney.period == .night)
            #expect(sydney.transition?.hasPrefix("Daylight saving ends") == true && !sydney.transitionSoon)

            let tokyo = presenter.row(try city("tokyo"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(tokyo.transition == "No daylight saving" && tokyo.detail.hasPrefix("JST"))

            let kathmandu = presenter.row(try city("kathmandu"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(kathmandu.subtitle.hasSuffix("2 h 15 min behind Beijing"))

            let offset = presenter.row(try city("utc:+0530"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(offset.subtitle.hasPrefix("Fixed offset"))
            #expect(offset.transition == "Fixed offset, no daylight saving")
            #expect(offset.detail == "UTC+5:30")

            let utc = presenter.row(try city("utc:+0000"), at: WorldClockFixtures.now, timeline: timeline)
            #expect(utc.name == "UTC" && utc.time == "10:24")
            #expect(!utc.isDaylightSaving && utc.detail == "UTC")
            #expect(utc.transition == "Fixed offset, no daylight saving")

            let local = presenter.row(try city("beijing"), isLocal: true, at: WorldClockFixtures.now,
                                      timeline: timeline)
            #expect(local.subtitle.hasSuffix(" · Local") && local.period == .twilight)

            // After local midnight, Los Angeles is still on the previous day.
            let late = WorldClockFixtures.utc("2026-10-22T16:30:00Z")
            let lateTimeline = WorldClockTimeline(showing: late, localZone: WorldClockFixtures.shanghai)
            let losAngeles = presenter.row(try city("losangeles"), at: late, timeline: lateTimeline)
            #expect(losAngeles.differentDay && losAngeles.day.hasPrefix("Today"))
            #expect(presenter.row(try city("beijing"), at: late, timeline: lateTimeline).day.hasPrefix("Tomorrow"))
        }
    }

    @Test func `bars mark working hours weekends and nights`() throws {
        let presenter = presenter()
        let timeline = WorldClockTimeline(showing: WorldClockFixtures.now, localZone: WorldClockFixtures.shanghai)
        let beijing = presenter.slots(WorldClockFixtures.shanghai, timeline: timeline)
        #expect(beijing[0] == .night && beijing[18] == .work && beijing[16] == .awake && beijing[47] == .night)
        let saturday = WorldClockTimeline(showing: WorldClockFixtures.utc("2026-10-24T04:00:00Z"),
                                          localZone: WorldClockFixtures.shanghai)
        #expect(presenter.slots(WorldClockFixtures.shanghai, timeline: saturday)[20] == .rest)
        let markers = presenter.markers(try city("newyork").timeZone, timeline: timeline)
        #expect(markers.filter(\.midnight).count == 1)
        #expect(markers.allSatisfy { $0.fraction > 0 && $0.fraction < 1 })
        let fraction = timeline.fraction(of: WorldClockFixtures.now)
        #expect(fraction > 0.76 && fraction < 0.77)
    }

    @Test func `copied lines follow the format`() throws {
        try withEnglish {
            let newYork = try city("newyork")
            let presenter = presenter()
            #expect(presenter.line(newYork, at: WorldClockFixtures.now, format: .city) == "New York 06:24")
            #expect(presenter.line(newYork, at: WorldClockFixtures.now, format: .time) == "06:24")
            #expect(presenter.line(newYork, at: WorldClockFixtures.now, format: .iso) == "2026-10-22T06:24:00-04:00")
            #expect(presenter.line(newYork, at: WorldClockFixtures.now) == "New York Thu, Oct 22 06:24")
            let twelve = self.presenter(.init(options: [WorldClockPreferences.hourFormatOption: "12"],
                                              localZone: WorldClockFixtures.shanghai))
            #expect(twelve.time(WorldClockFixtures.now, in: newYork.timeZone).contains("6:24"))
            #expect(!twelve.uses24Hour)
            let chinese = self.presenter(language: .simplifiedChinese)
            #expect(chinese.line(newYork, at: WorldClockFixtures.now, format: .city) == "纽约 06:24")
        }
    }

    @Test func `the hint row summarises the local time and cities`() {
        withEnglish {
            let summary = AskWorldClockPlugin.summary(
                options: [WorldClockPreferences.citiesOption: #"["newyork","london","tokyo"]"#,
                          WorldClockPreferences.hourFormatOption: "24",
                          WorldClockPreferences.hintCountOption: "2"],
                now: WorldClockFixtures.now, language: .english, localZone: WorldClockFixtures.shanghai
            )
            #expect(summary == "Shanghai 18:24 · New York 06:24 · London 11:24")
        }
    }

    @Test func `the default hint includes UTC as a reference`() {
        withEnglish {
            let summary = AskWorldClockPlugin.summary(
                options: [WorldClockPreferences.hourFormatOption: "24"],
                now: WorldClockFixtures.now, language: .english, localZone: WorldClockFixtures.shanghai
            )
            #expect(summary == "Shanghai 18:24 · UTC 10:24 · San Francisco 03:24 · New York 06:24 · London 11:24")
        }
    }
}

@Suite("World clock preferences")
struct WorldClockPreferencesTests {
    @Test func `defaults cover representative zones and skip the local zone`() {
        let shanghai = WorldClockPreferences(options: [:], localZone: WorldClockFixtures.shanghai)
        #expect(shanghai.cityIDs == ["utc:+0000", "sanfrancisco", "newyork", "london", "berlin", "mumbai",
                                     "tokyo", "sydney"])
        let tokyo = WorldClockPreferences(options: [:], localZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo.cityIDs == ["utc:+0000", "sanfrancisco", "newyork", "london", "berlin", "mumbai",
                                  "beijing", "sydney"])
        let singapore = WorldClockPreferences(options: [:], localZone: TimeZone(identifier: "Asia/Singapore")!)
        #expect(singapore.cityIDs.contains("beijing") && singapore.cityIDs.count == 9)
        let utc = WorldClockPreferences(options: [:], localZone: TimeZone(secondsFromGMT: 0)!)
        #expect(!utc.cityIDs.contains("utc:+0000") && utc.cityIDs.count == 8)
        let london = WorldClockPreferences(options: [:], localZone: TimeZone(identifier: "Europe/London")!)
        #expect(london.cityIDs.contains("utc:+0000") && !london.cityIDs.contains("london"))
        #expect(shanghai.workStart == 540 && shanghai.workEnd == 1080 && shanghai.workdays == [2, 3, 4, 5, 6])
        #expect(shanghai.step == 30 && shanghai.hintCount == 4 && shanghai.copyFormat == .full)
        #expect(shanghai.meetingAbbreviations && shanghai.hourFormat == .system)
    }

    @Test func `saved lists including empty lists retain the users choices`() {
        for ids in [[], ["newyork", "london"], ["sanfrancisco", "newyork", "london", "tokyo"]] as [[String]] {
            var preferences = WorldClockPreferences(localZone: WorldClockFixtures.shanghai)
            preferences.cityIDs = ids
            var options: [String: String] = [:]
            preferences.write(into: &options)
            #expect(WorldClockPreferences(options: options, localZone: WorldClockFixtures.shanghai).cityIDs == ids)
        }
    }

    @Test func `settings round trip and keep unknown options`() {
        var preferences = WorldClockPreferences(options: [:], localZone: WorldClockFixtures.shanghai)
        preferences.cityIDs = ["london", "utc:+0530"]
        preferences.labels = ["london": "Design", "tokyo": "  "]
        preferences.hourFormat = .twelve
        preferences.workStart = 600
        preferences.workEnd = 1140
        preferences.workdays = [1, 2, 3, 4, 5]
        preferences.step = 15
        preferences.hintCount = 2
        preferences.copyFormat = .iso
        preferences.meetingAbbreviations = false
        var options = ["custom": "kept"]
        preferences.write(into: &options)
        #expect(options["custom"] == "kept")
        let read = WorldClockPreferences(options: options, localZone: WorldClockFixtures.shanghai)
        #expect(read == preferences)
        #expect(read.label(for: "london") == "Design" && read.label(for: "tokyo") == nil)
        #expect(read.uses24Hour() == false)

        var defaults = WorldClockPreferences(options: options, localZone: WorldClockFixtures.shanghai)
        defaults.labels = [:]
        defaults.hourFormat = .system
        defaults.workStart = 540
        defaults.workEnd = 1080
        defaults.workdays = [2, 3, 4, 5, 6]
        defaults.step = 30
        defaults.hintCount = 4
        defaults.copyFormat = .full
        defaults.meetingAbbreviations = true
        defaults.write(into: &options)
        #expect(Set(options.keys) == ["custom", WorldClockPreferences.citiesOption])
    }

    @Test func `invalid values fall back`() {
        let preferences = WorldClockPreferences(options: [
            WorldClockPreferences.citiesOption: "not json",
            WorldClockPreferences.labelsOption: "[",
            WorldClockPreferences.workStartOption: "1200",
            WorldClockPreferences.workEndOption: "600",
            WorldClockPreferences.workdaysOption: "",
            WorldClockPreferences.stepOption: "7",
            WorldClockPreferences.hintCountOption: "99",
            WorldClockPreferences.copyFormatOption: "fancy",
            WorldClockPreferences.hourFormatOption: "36",
            WorldClockPreferences.meetingZonesOption: "false"
        ], localZone: WorldClockFixtures.shanghai)
        #expect(preferences.cityIDs.count == 8 && preferences.labels.isEmpty)
        #expect(preferences.workStart == 540 && preferences.workEnd == 1080)
        #expect(preferences.workdays.isEmpty)
        #expect(preferences.step == 30 && preferences.hintCount == 6)
        #expect(preferences.copyFormat == .full && preferences.hourFormat == .system)
        #expect(!preferences.meetingAbbreviations)
        #expect(WorldClockPreferences(options: [WorldClockPreferences.hourFormatOption: "24"]).uses24Hour())
    }
}

@Suite("World clock meeting times")
struct MeetingSlotFinderTests {
    let finder = MeetingSlotFinder(
        preferences: WorldClockPreferences(options: [:], localZone: WorldClockFixtures.shanghai)
    )

    private func zone(_ id: String) -> TimeZone {
        TimeZone(identifier: id)!
    }

    @Test func `places that share working hours get the overlap`() throws {
        let result = finder.find([zone("Asia/Shanghai"), zone("Asia/Tokyo")], after: WorldClockFixtures.now)
        let overlap = try #require(result.overlap)
        // Friday 09:00–17:00 in Beijing: Tokyo ends at 18:00 there.
        #expect(overlap.lowerBound == WorldClockFixtures.utc("2026-10-23T01:00:00Z"))
        #expect(overlap.upperBound == WorldClockFixtures.utc("2026-10-23T09:00:00Z"))
        #expect(result.suggestions.count == 3 && result.suggestions.allSatisfy(\.fits))
    }

    @Test func `places that never overlap get three distinct times`() {
        let result = finder.find([zone("Asia/Shanghai"), zone("America/New_York"), zone("Europe/London")],
                                 after: WorldClockFixtures.now)
        #expect(result.overlap == nil)
        #expect(result.suggestions.count == 3)
        let starts = result.suggestions.map(\.start)
        #expect(starts == starts.sorted())
        for (index, first) in starts.enumerated() {
            for second in starts[(index + 1)...] {
                let gap = abs(first.timeIntervalSince(second)).truncatingRemainder(dividingBy: 86400)
                #expect(min(gap, 86400 - gap) >= 3600)
            }
        }
        #expect(result.suggestions.allSatisfy { !$0.fits && $0.start > WorldClockFixtures.now })
    }

    @Test func `nights and weekends cost more`() {
        let london = zone("Europe/London")
        let weekday = finder.cost(of: WorldClockFixtures.utc("2026-10-22T10:00:00Z"), in: london)
        let saturday = finder.cost(of: WorldClockFixtures.utc("2026-10-24T10:00:00Z"), in: london)
        let night = finder.cost(of: WorldClockFixtures.utc("2026-10-22T02:00:00Z"), in: london)
        let evening = finder.cost(of: WorldClockFixtures.utc("2026-10-22T18:00:00Z"), in: london)
        #expect(weekday == 0 && saturday >= 12 && night > evening && evening > 0)
        #expect(finder.find([], after: WorldClockFixtures.now) == .init(overlap: nil, suggestions: []))
    }
}
