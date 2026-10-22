import Foundation

/// One place as the world clock lists it: the text and the 24-hour bar, computed without any view.
struct WorldClockRow: Identifiable, Equatable {
    enum Period: Equatable {
        case day, twilight, night
    }

    /// Half an hour of the bar, read in the row's own zone.
    enum Slot: Equatable {
        case work, awake, night, rest
    }

    struct Marker: Equatable {
        /// 0 is the left edge of the bar, 1 the right.
        var fraction: Double
        var text: String
        /// Local midnight: a line and the new weekday rather than an hour.
        var midnight: Bool
    }

    let city: WorldClockCity
    let name: String
    let label: String?
    let isLocal: Bool
    let isDaylightSaving: Bool
    let time: String
    /// "Today Thu", "Tomorrow Fri".
    let day: String
    /// The row's date differs from the local date at the same moment.
    let differentDay: Bool
    /// "United States · 12 hours behind Beijing".
    let subtitle: String
    let period: Period
    let slots: [Slot]
    let markers: [Marker]
    /// "EDT · UTC−4 · America/New_York".
    let detail: String
    /// The next daylight saving change and the difference after it.
    let transition: String?
    /// The change is within 30 days: worth a warning colour.
    let transitionSoon: Bool

    var id: String {
        city.id
    }
}

/// The 24 hours every bar spans: the local day the shown moment falls on.
struct WorldClockTimeline: Equatable {
    static let slotCount = 48
    let start: Date

    init(showing moment: Date, localZone: TimeZone) {
        start = WorldClockFormat.calendar(localZone).startOfDay(for: moment)
    }

    func fraction(of date: Date) -> Double {
        date.timeIntervalSince(start) / 86400
    }
}

/// Builds rows. Every input is explicit so tests can pin the moment, the zone and the language.
struct WorldClockPresenter {
    var preferences: WorldClockPreferences
    var language: AppLanguage
    var now: Date
    var localZone: TimeZone
    /// What the local row is called, used in "behind Beijing".
    var localName: String

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    var uses24Hour: Bool {
        preferences.uses24Hour(locale: locale)
    }

    func time(_ date: Date, in zone: TimeZone) -> String {
        WorldClockFormat.time(date, in: zone, uses24Hour: uses24Hour, locale: locale)
    }

    /// "New York Thu, Oct 22 06:24", shaped by the copy format.
    func line(_ city: WorldClockCity, at date: Date, format: WorldClockPreferences.CopyFormat? = nil) -> String {
        let zone = city.timeZone, name = city.name(in: language)
        switch format ?? preferences.copyFormat {
        case .full: return "\(name) \(WorldClockFormat.day(date, in: zone, locale: locale)) \(time(date, in: zone))"
        case .city: return "\(name) \(time(date, in: zone))"
        case .time: return time(date, in: zone)
        case .iso: return WorldClockFormat.iso(date, in: zone)
        }
    }

    func row(_ city: WorldClockCity, isLocal: Bool = false, at moment: Date, timeline: WorldClockTimeline) -> WorldClockRow {
        let zone = city.timeZone
        let calendar = WorldClockFormat.calendar(zone)
        let hour = calendar.component(.hour, from: moment)
        let delta = WorldClockFormat.dayDelta(moment, in: zone, from: now, in: localZone)
        let sameMoment = WorldClockFormat.dayDelta(moment, in: zone, from: moment, in: localZone)
        let offset = zone.secondsFromGMT(for: moment) - localZone.secondsFromGMT(for: moment)
        let place = city.country(in: language) ?? (city.isFixedOffset ? L("worldclock.fixedOffset") : zone.identifier)
        let relation = isLocal ? L("worldclock.local") : WorldClockFormat.difference(seconds: offset, from: localName)
        let (transition, soon) = transitionNote(city)
        var detailParts: [String] = []
        for part in [WorldClockAbbreviations.abbreviation(zone, at: moment),
                     WorldClockFormat.utcOffset(seconds: zone.secondsFromGMT(for: moment)),
                     city.isFixedOffset ? nil : zone.identifier].compactMap({ $0 }) where !detailParts.contains(part) {
            detailParts.append(part)
        }
        let detail = detailParts.joined(separator: " · ")
        return WorldClockRow(
            city: city, name: city.name(in: language), label: preferences.label(for: city.id), isLocal: isLocal,
            isDaylightSaving: zone.isDaylightSavingTime(for: moment), time: time(moment, in: zone),
            day: WorldClockFormat.dayWord(delta: delta, date: moment, in: zone, locale: locale) + " "
                + WorldClockFormat.weekday(moment, in: zone, locale: locale),
            differentDay: sameMoment != 0, subtitle: place + " · " + relation,
            period: (7 ..< 18).contains(hour) ? .day : (5 ..< 7).contains(hour) || (18 ..< 21).contains(hour)
                ? .twilight : .night,
            slots: slots(zone, timeline: timeline), markers: markers(zone, timeline: timeline),
            detail: detail, transition: transition, transitionSoon: soon
        )
    }

    func slots(_ zone: TimeZone, timeline: WorldClockTimeline) -> [WorldClockRow.Slot] {
        let calendar = WorldClockFormat.calendar(zone)
        return (0 ..< WorldClockTimeline.slotCount).map { index in
            let moment = timeline.start.addingTimeInterval(Double(index) * 1800 + 900)
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: moment)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let working = (preferences.workStart ..< preferences.workEnd).contains(minutes)
            if working { return preferences.workdays.contains(parts.weekday ?? 1) ? .work : .rest }
            return (7 * 60 ..< 22 * 60).contains(minutes) ? .awake : .night
        }
    }

    func markers(_ zone: TimeZone, timeline: WorldClockTimeline) -> [WorldClockRow.Marker] {
        let calendar = WorldClockFormat.calendar(zone)
        var markers: [WorldClockRow.Marker] = []
        var day = calendar.startOfDay(for: timeline.start)
        for _ in 0 ..< 3 {
            let midnight = timeline.fraction(of: day)
            if midnight > 0, midnight < 1 {
                markers.append(.init(fraction: midnight,
                                     text: WorldClockFormat.weekday(day, in: zone, locale: locale), midnight: true))
            }
            for hour in [6, 12, 18] {
                guard let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                let fraction = timeline.fraction(of: moment)
                if fraction > 0.05, fraction < 0.95 {
                    markers.append(.init(fraction: fraction, text: String(hour), midnight: false))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        // An hour label too close to a weekday would overlap it.
        let midnights = markers.filter(\.midnight).map(\.fraction)
        return markers.filter { marker in
            marker.midnight || !midnights.contains { marker.fraction > $0 - 0.03 && marker.fraction < $0 + 0.1 }
        }
    }

    /// "In 3 days (Oct 25 02:00) daylight saving ends, then 8 hours behind Beijing".
    func transitionNote(_ city: WorldClockCity) -> (String?, Bool) {
        let zone = city.timeZone
        if city.isFixedOffset { return (L("worldclock.dst.fixed"), false) }
        guard let change = zone.nextDaylightSavingTimeTransition(after: now) else {
            return (L("worldclock.dst.none"), false)
        }
        let before = zone.secondsFromGMT(for: change.addingTimeInterval(-1))
        let after = zone.secondsFromGMT(for: change.addingTimeInterval(1))
        let wall = TimeZone(secondsFromGMT: before) ?? zone
        let when = WorldClockFormat.day(change, in: wall, locale: locale) + " " + time(change, in: wall)
        let days = Int(ceil(change.timeIntervalSince(now) / 86400))
        let soon = days <= 30
        let moment = soon ? L("worldclock.dst.soon", days, when) : when
        let difference = WorldClockFormat.difference(
            seconds: after - localZone.secondsFromGMT(for: change.addingTimeInterval(1)), from: localName
        )
        return (L(after > before ? "worldclock.dst.starts" : "worldclock.dst.ends", moment, difference), soon)
    }
}
