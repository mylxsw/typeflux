import Foundation

/// Every place the world clock can find: the bundled city table, then each system
/// time zone under its exemplar city ("Kolkata"), so less common zones are still reachable.
struct WorldCityDirectory: Sendable {
    private struct Entry: Sendable {
        let city: WorldClockCity
        /// Lowercased, accent-free names, aliases and pinyin.
        let names: [String]
        /// Country names and the zone id: they match too, after the names.
        let others: [String]

        var keys: [String] {
            names + others
        }
    }

    private let entries: [Entry]
    private let byID: [String: WorldClockCity]
    /// Each zone's own city in English, folded: "Asia/Shanghai" → "shanghai".
    private let exemplars: [String: String]

    /// The bundled table plus the system zones, loaded once on first use.
    static let shared = WorldCityDirectory(bundled: Self.bundledCities(),
                                           zoneIdentifiers: TimeZone.knownTimeZoneIdentifiers)

    init(bundled: [WorldClockCity], zoneIdentifiers: [String]) {
        var cities = bundled
        var exemplars: [String: String] = [:]
        let covered = Set(bundled.flatMap { city in
            [city.timeZone.identifier + "|" + Self.fold(city.name(in: .english))]
        })
        let formatters = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map {
            ($0, Self.exemplarFormatter(Locale(identifier: $0.localeIdentifier)))
        })
        let english = formatters[.english] ?? Self.exemplarFormatter(Locale(identifier: "en"))
        for identifier in zoneIdentifiers where Self.regions.contains(where: { identifier.hasPrefix($0 + "/") }) {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let name = Self.exemplarCity(zone, formatter: english)
            exemplars[identifier] = Self.fold(name)
            guard !covered.contains(identifier + "|" + Self.fold(name)) else { continue }
            var names: [String: String] = [:]
            for (language, formatter) in formatters {
                names[language.rawValue] = Self.exemplarCity(zone, formatter: formatter)
            }
            cities.append(WorldClockCity(id: WorldClockCity.zonePrefix + identifier, timeZone: zone, countryCode: nil,
                                         population: 0, names: names, aliases: []))
        }
        self.exemplars = exemplars
        entries = cities.map { Entry(city: $0, names: Self.nameKeys(for: $0), others: Self.otherKeys(for: $0)) }
        byID = Dictionary(cities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var cities: [WorldClockCity] {
        entries.map(\.city)
    }

    func city(id: String) -> WorldClockCity? {
        byID[id] ?? WorldClockCity.fromStoredID(id)
    }

    /// The city a zone is named after ("Asia/Shanghai" → Shanghai, not a larger city sharing the zone),
    /// else its most populous city; used for abbreviations and the local zone.
    func representative(of zone: TimeZone) -> WorldClockCity? {
        let inZone = entries.filter { $0.city.timeZone.identifier == zone.identifier }.map(\.city)
        if let exemplar = exemplars[zone.identifier],
           let named = inZone.first(where: { Self.fold($0.name(in: .english)) == exemplar }) {
            return named
        }
        return inZone.max { $0.population < $1.population }
    }

    /// The names a token stands for exactly: a city, an abbreviation ("PST", "IST" names three),
    /// a zone id ("Asia/Tokyo") or a fixed offset ("UTC+5:30").
    func resolve(_ token: String) -> [WorldClockCity] {
        let key = Self.fold(token)
        guard !key.isEmpty else { return [] }
        if let offset = Self.offsetMinutes(key) {
            return WorldClockCity.fixedOffset(minutes: offset).map { [$0] } ?? []
        }
        if let zones = WorldClockAbbreviations.zones[key.uppercased()] {
            return zones.compactMap { TimeZone(identifier: $0) }.compactMap { zone in
                representative(of: zone) ?? city(id: WorldClockCity.zonePrefix + zone.identifier)
            }
        }
        return entries.filter { $0.keys.contains(key) }
            .sorted { $0.city.population > $1.city.population }
            .map(\.city)
    }

    /// Exact names first, then names that start with the query, then countries and zones that do,
    /// then any part of a name; more populous first within each.
    func search(_ query: String, limit: Int = 30) -> [WorldClockCity] {
        let key = Self.fold(query)
        guard !key.isEmpty else { return [] }
        let exact = resolve(query)
        var scored: [(city: WorldClockCity, score: Int)] = []
        for entry in entries where !exact.contains(entry.city) {
            if entry.names.contains(where: { $0.hasPrefix(key) }) {
                scored.append((entry.city, 1))
            } else if entry.others.contains(where: { $0.hasPrefix(key) }) {
                scored.append((entry.city, 2))
            } else if key.count >= 2, entry.keys.contains(where: { $0.contains(key) }) {
                scored.append((entry.city, 3))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.city.population > $1.city.population }
        return Array((exact + scored.map(\.city)).prefix(limit))
    }

    // MARK: - Building

    static let regions = ["Africa", "America", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"]

    /// The system's name for the zone's city in a language ("Asia/Kolkata" → "加尔各答").
    static func exemplarCity(_ identifier: String, locale: Locale) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        return exemplarCity(zone, formatter: exemplarFormatter(locale))
    }

    private static func exemplarFormatter(_ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "VVV"
        return formatter
    }

    private static func exemplarCity(_ zone: TimeZone, formatter: DateFormatter) -> String {
        formatter.timeZone = zone
        let name = formatter.string(from: Date(timeIntervalSince1970: 0))
        if name.isEmpty || name.contains("GMT") || name.contains("/") {
            return zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
                ?? zone.identifier
        }
        return name
    }

    private static func nameKeys(for city: WorldClockCity) -> [String] {
        var keys = Set<String>()
        for name in city.names.values + city.aliases {
            keys.insert(fold(name))
        }
        if let chinese = city.names[AppLanguage.simplifiedChinese.rawValue] {
            let syllables = pinyin(chinese)
            if !syllables.isEmpty {
                keys.insert(syllables.joined())
                keys.insert(String(syllables.compactMap(\.first)))
            }
        }
        keys.remove("")
        return Array(keys)
    }

    private static func otherKeys(for city: WorldClockCity) -> [String] {
        var keys = Set<String>()
        if let code = city.countryCode {
            for language in AppLanguage.allCases {
                if let country = Locale(identifier: language.localeIdentifier).localizedString(forRegionCode: code) {
                    keys.insert(fold(country))
                }
            }
        }
        if !city.isFixedOffset {
            keys.insert(fold(city.timeZone.identifier))
        }
        keys.remove("")
        return Array(keys)
    }

    /// Lowercased, accents and width folded, spaces collapsed: "São Paulo" → "sao paulo".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Pinyin syllables without tones: "旧金山" → ["jiu", "jin", "shan"]. Empty for text without Han characters.
    static func pinyin(_ text: String) -> [String] {
        guard text.unicodeScalars.contains(where: { (0x4E00 ... 0x9FFF).contains($0.value) }) else { return [] }
        let latin = NSMutableString(string: text)
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
        return (latin as String).lowercased().split(separator: " ").map(String.init)
    }

    /// "utc+8", "gmt-5", "utc+5:30", "utc" → minutes east of UTC.
    static func offsetMinutes(_ key: String) -> Int? {
        let compact = key.replacingOccurrences(of: " ", with: "")
        guard compact.hasPrefix("utc") || compact.hasPrefix("gmt") else { return nil }
        let rest = compact.dropFirst(3)
        if rest.isEmpty { return 0 }
        guard let sign = rest.first, sign == "+" || sign == "-" || sign == "−" else { return nil }
        let parts = rest.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), let hours = Int(parts[0]), parts[0].count <= 2 else { return nil }
        let minutes = parts.count == 2 ? Int(parts[1]) : 0
        guard let minutes, (0 ..< 60).contains(minutes) else { return nil }
        return (sign == "+" ? 1 : -1) * (hours * 60 + minutes)
    }

    static func bundledCities(bundle: Bundle = .module) -> [WorldClockCity] {
        guard let url = bundle.url(forResource: "world-cities", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func decode(_ data: Data) -> [WorldClockCity] {
        guard let table = try? JSONDecoder().decode(WorldCityTable.self, from: data) else { return [] }
        return table.cities.compactMap { row in
            guard let zone = TimeZone(identifier: row.zone), row.names[AppLanguage.english.rawValue] != nil else {
                return nil
            }
            return WorldClockCity(id: row.id, timeZone: zone, countryCode: row.country, population: row.population ?? 0,
                                  names: row.names, aliases: row.aliases ?? [])
        }
    }
}

/// `world-cities.json`: short keys keep the bundled file small.
private struct WorldCityTable: Decodable {
    let cities: [WorldCityRow]
}

private struct WorldCityRow: Decodable {
    let id: String
    let zone: String
    let country: String?
    let population: Int?
    let names: [String: String]
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case id, names, aliases
        case zone = "tz", country = "cc", population = "pop"
    }
}
