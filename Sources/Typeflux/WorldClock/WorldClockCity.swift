import Foundation

/// A place the world clock can show: a bundled city, a system time zone, or a fixed UTC offset.
struct WorldClockCity: Identifiable, Hashable, Sendable {
    /// Bundled cities use their table id ("beijing"); zones "tz:Asia/Kolkata"; offsets "utc:+0530".
    let id: String
    let timeZone: TimeZone
    let countryCode: String?
    /// Thousands of people in the metro area; ranks equally good search matches.
    let population: Int
    /// Names keyed by `AppLanguage.rawValue`; English is always present.
    let names: [String: String]
    /// Other English names people type: "bangalore", "nyc".
    let aliases: [String]

    static let zonePrefix = "tz:"
    static let offsetPrefix = "utc:"

    var isFixedOffset: Bool {
        id.hasPrefix(Self.offsetPrefix)
    }

    func name(in language: AppLanguage) -> String {
        names[language.rawValue] ?? names[AppLanguage.english.rawValue] ?? timeZone.identifier
    }

    /// The country's name in the interface language; fixed offsets have none.
    func country(in language: AppLanguage) -> String? {
        guard let countryCode else { return nil }
        return Locale(identifier: language.localeIdentifier).localizedString(forRegionCode: countryCode)
    }

    /// A city for "UTC+5:30"; nil outside the offsets clocks actually use (−12 to +14 hours).
    static func fixedOffset(minutes: Int) -> WorldClockCity? {
        guard (-12 * 60 ... 14 * 60).contains(minutes), let zone = TimeZone(secondsFromGMT: minutes * 60) else {
            return nil
        }
        let label = WorldClockFormat.utcOffset(seconds: minutes * 60)
        let sign = minutes < 0 ? "-" : "+"
        let id = Self.offsetPrefix + sign + String(format: "%02d%02d", abs(minutes) / 60, abs(minutes) % 60)
        return WorldClockCity(id: id, timeZone: zone, countryCode: nil, population: 0,
                              names: [AppLanguage.english.rawValue: label], aliases: [])
    }

    /// Rebuilds a city from an id that is not in the directory (offsets, or a zone the table dropped).
    static func fromStoredID(_ id: String) -> WorldClockCity? {
        if id.hasPrefix(offsetPrefix) {
            let digits = id.dropFirst(offsetPrefix.count)
            guard digits.count == 5, let hours = Int(digits.dropFirst().prefix(2)),
                  let minutes = Int(digits.suffix(2)) else { return nil }
            return fixedOffset(minutes: (digits.first == "-" ? -1 : 1) * (hours * 60 + minutes))
        }
        if id.hasPrefix(zonePrefix), let zone = TimeZone(identifier: String(id.dropFirst(zonePrefix.count))) {
            let city = WorldCityDirectory.exemplarCity(zone.identifier, locale: Locale(identifier: "en"))
            return WorldClockCity(id: id, timeZone: zone, countryCode: nil, population: 0,
                                  names: [AppLanguage.english.rawValue: city], aliases: [])
        }
        return nil
    }
}
