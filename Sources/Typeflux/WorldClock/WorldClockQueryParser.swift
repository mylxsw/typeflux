import Foundation

/// What the text after the world clock keyword asks for.
enum WorldClockQuery: Equatable {
    /// Nothing typed: the user's cities.
    case list
    /// Cities matching a name; the first is the best match.
    case search([WorldClockCity])
    /// "明天 9am 纽约": a moment in one place, read in another.
    case convert(WorldClockConversion)
    /// "北京 纽约 伦敦": when these places can meet.
    case meeting([WorldClockCity])
    /// A Unix timestamp or ISO 8601 time.
    case timestamp(Date, WorldClockTimestampKind)
    /// Neither a place nor a time.
    case unknown(String)
}

struct WorldClockConversion: Equatable {
    /// Where the typed time is read; nil is the local time zone.
    var source: WorldClockCity?
    /// The place asked about; nil shows every city against the source.
    var target: WorldClockCity?
    var date: Date
    /// The typed time does not exist there (a daylight saving gap) and moved to the next valid time.
    var adjusted: Bool
}

enum WorldClockTimestampKind: Equatable {
    case now, seconds, milliseconds, iso
}

/// Reads the world clock's input. Pure: "now" and the local zone are injected for tests.
struct WorldClockQueryParser {
    let directory: WorldCityDirectory
    let now: Date
    let localZone: TimeZone

    static let nowWords: Set<String> = ["now", "ts", "unix", "timestamp", "epoch", "时间戳", "時間戳", "タイムスタンプ", "타임스탬프"]

    func parse(_ text: String) -> WorldClockQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .list }
        if let stamp = timestamp(trimmed) { return stamp }
        // A whole place name ("UTC+5:30", "New York") is a search even when it looks like a time.
        let exact = directory.resolve(trimmed)
        if exact.isEmpty, let conversion = conversion(trimmed) { return conversion }
        if exact.isEmpty, let meeting = meeting(trimmed) { return meeting }
        let cities = directory.search(trimmed)
        return cities.isEmpty ? .unknown(trimmed) : .search(cities)
    }

    // MARK: - Timestamps

    private func timestamp(_ text: String) -> WorldClockQuery? {
        if Self.nowWords.contains(text.lowercased()) { return .timestamp(now, .now) }
        if text.count == 10 || text.count == 13, text.allSatisfy(\.isASCII), let value = Int64(text), value > 0 {
            return text.count == 10 ? .timestamp(Date(timeIntervalSince1970: TimeInterval(value)), .seconds)
                : .timestamp(Date(timeIntervalSince1970: TimeInterval(value) / 1000), .milliseconds)
        }
        guard text.count >= 16, text.first?.isNumber == true else { return nil }
        let normalized = text.replacingOccurrences(of: " ", with: "T")
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime],
                                                      [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: normalized) { return .timestamp(date, .iso) }
        }
        return nil
    }

    // MARK: - Meetings

    private func meeting(_ text: String) -> WorldClockQuery? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || ",，、;；".contains($0) }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        var cities: [WorldClockCity] = []
        var index = 0
        // Longest names first, so "New York London" is two places, not three.
        while index < tokens.count {
            var found: (city: WorldClockCity, length: Int)?
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let name = tokens[index ..< index + length].joined(separator: " ")
                if let city = directory.resolve(name).first {
                    found = (city, length)
                    break
                }
            }
            guard let found else { return nil }
            if !cities.contains(where: { $0.id == found.city.id }) { cities.append(found.city) }
            index += found.length
        }
        return cities.count >= 2 ? .meeting(cities) : nil
    }

    // MARK: - Conversions

    private static let separator = try? NSRegularExpression(
        pattern: #"\s*(?:→|->|=>|到|至|\bto\b|\bin\b)\s*"#, options: [.caseInsensitive]
    )

    private func conversion(_ text: String) -> WorldClockQuery? {
        var sourceText = text, targetText: String?
        let whole = NSRange(text.startIndex..., in: text)
        if let match = Self.separator?.firstMatch(in: text, range: whole), let range = Range(match.range, in: text) {
            sourceText = String(text[..<range.lowerBound])
            targetText = String(text[range.upperBound...])
        }
        guard let time = WorldClockTimeText.time(in: sourceText) else { return nil }
        var rest = time.rest
        let day = WorldClockTimeText.day(in: &rest)
        let place = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        var source: WorldClockCity?
        if !place.isEmpty {
            guard let city = directory.resolve(place).first ?? directory.search(place, limit: 1).first else {
                return .unknown(text)
            }
            source = city
        }
        var target: WorldClockCity?
        if let targetText {
            let name = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let city = directory.resolve(name).first ?? directory.search(name, limit: 1).first
            else { return .unknown(text) }
            target = city
        }
        let zone = source?.timeZone ?? localZone
        let calendar = WorldClockFormat.calendar(zone)
        guard let date = day.date(today: now, calendar: calendar) else { return .unknown(text) }
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = time.hour
        parts.minute = time.minute
        guard let moment = calendar.date(from: parts) else { return .unknown(text) }
        let landed = calendar.dateComponents([.hour, .minute], from: moment)
        if target == nil, source != nil, source?.timeZone.identifier != localZone.identifier {
            // "9am New York" asks what that is here.
            target = directory.representative(of: localZone)
                ?? directory.city(id: WorldClockCity.zonePrefix + localZone.identifier)
        }
        return .convert(WorldClockConversion(source: source, target: target, date: moment,
                                             adjusted: landed.hour != time.hour || landed.minute != time.minute))
    }
}
