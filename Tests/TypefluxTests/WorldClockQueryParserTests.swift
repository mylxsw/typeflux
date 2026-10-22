import Foundation
import Testing
@testable import Typeflux

enum WorldClockFixtures {
    /// Thu 2026-10-22 10:24 UTC: 18:24 in Beijing, three days before London leaves daylight saving.
    static let now = Date(timeIntervalSince1970: 1_792_664_640)
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let directory = WorldCityDirectory.shared
    static let listOptions = [WorldClockPreferences.citiesOption: #"["newyork","london","tokyo"]"#,
                              WorldClockPreferences.hourFormatOption: "24"]

    static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static var parser: WorldClockQueryParser {
        WorldClockQueryParser(directory: directory, now: now, localZone: shanghai)
    }
}

@Suite("World clock input")
struct WorldClockQueryParserTests {
    private func parse(_ text: String) -> WorldClockQuery {
        WorldClockFixtures.parser.parse(text)
    }

    private func conversion(_ text: String) throws -> WorldClockConversion {
        guard case let .convert(conversion) = parse(text) else {
            Issue.record("\(text) is not a conversion: \(parse(text))")
            throw CancellationError()
        }
        return conversion
    }

    private func firstCity(_ text: String) -> String? {
        if case let .search(cities) = parse(text) { return cities.first?.id }
        return nil
    }

    @Test func `empty input lists the cities`() {
        #expect(parse("  ") == .list)
    }

    @Test func `names pinyin english and accents find the same city`() {
        for text in ["伦敦", "倫敦", "London", "lundun", "ld", "ロンドン", "런던", "Europe/London"] {
            #expect(firstCity(text) == "london", "\(text)")
        }
        #expect(firstCity("sao paulo") == "saopaulo")
        #expect(firstCity("São") == "saopaulo")
        #expect(firstCity("bangalore") == "bengaluru")
        #expect(firstCity("san francisco") == "sanfrancisco")
        #expect(firstCity("Asia/Tokyo") == "tokyo")
    }

    @Test func `abbreviations and offsets name zones`() {
        #expect(firstCity("PST") == "losangeles")
        guard case let .search(ist) = parse("IST") else { Issue.record("IST"); return }
        #expect(Set(ist.prefix(3).map(\.timeZone.identifier)) == ["Asia/Kolkata", "Europe/Dublin", "Asia/Jerusalem"])
        #expect(firstCity("UTC+5:30") == "utc:+0530")
        #expect(firstCity("gmt-3") == "utc:-0300")
    }

    @Test func `a time and a place convert to the local zone`() throws {
        let tomorrow = try conversion("明天 9am 纽约")
        #expect(tomorrow.source?.id == "newyork")
        #expect(tomorrow.target?.timeZone.identifier == "Asia/Shanghai")
        #expect(tomorrow.date == WorldClockFixtures.utc("2026-10-23T13:00:00Z"))
        #expect(!tomorrow.adjusted)

        let between = try conversion("15:00 伦敦 到 东京")
        #expect(between.source?.id == "london" && between.target?.id == "tokyo")
        #expect(between.date == WorldClockFixtures.utc("2026-10-22T14:00:00Z"))
        #expect(try conversion("3pm london to tokyo") == between)
        #expect(try conversion("15:00 伦敦 → 东京") == between)

        #expect(try conversion("下午3点半 PST").date == WorldClockFixtures.utc("2026-10-22T22:30:00Z"))
        let local = try conversion("晚上8点")
        #expect(local.source == nil && local.target == nil)
        #expect(local.date == WorldClockFixtures.utc("2026-10-22T12:00:00Z"))
    }

    @Test func `days are read in the source city`() throws {
        // London is back on GMT from Oct 25.
        #expect(try conversion("10-25 9:00 伦敦").date == WorldClockFixtures.utc("2026-10-25T09:00:00Z"))
        #expect(try conversion("2026年11月2日 9:00 纽约").date == WorldClockFixtures.utc("2026-11-02T14:00:00Z"))
        #expect(try conversion("下周五 10:00 东京").date == WorldClockFixtures.utc("2026-10-30T01:00:00Z"))
        #expect(try conversion("fri 10:00 tokyo").date == WorldClockFixtures.utc("2026-10-23T01:00:00Z"))
        #expect(try conversion("next monday 9am london").date == WorldClockFixtures.utc("2026-10-26T09:00:00Z"))
        #expect(try conversion("昨天 9:00").date == WorldClockFixtures.utc("2026-10-21T01:00:00Z"))
    }

    @Test func `a time skipped by daylight saving moves forward and says so`() throws {
        let skipped = try conversion("2027-03-14 2:30 纽约")
        #expect(skipped.adjusted)
        #expect(skipped.date == WorldClockFixtures.utc("2027-03-14T07:30:00Z"))
    }

    @Test func `bad times and unknown places are not conversions`() {
        if case .convert = parse("25:00 伦敦") { Issue.record("25:00 is not a time") }
        #expect(parse("9am 火星") == .unknown("9am 火星"))
        #expect(parse("9am 伦敦 到 火星") == .unknown("9am 伦敦 到 火星"))
        #expect(parse("2-30 9:00 伦敦") == .unknown("2-30 9:00 伦敦"))
        #expect(parse("火星") == .unknown("火星"))
    }

    @Test func `several places ask for a meeting time`() {
        guard case let .meeting(cities) = parse("北京 纽约 伦敦") else { Issue.record("meeting"); return }
        #expect(cities.map(\.id) == ["beijing", "newyork", "london"])
        guard case let .meeting(pair) = parse("北京、东京，北京") else { Issue.record("pair"); return }
        #expect(pair.map(\.id) == ["beijing", "tokyo"])
        guard case let .meeting(english) = parse("New York, San Francisco London") else {
            Issue.record("english")
            return
        }
        #expect(english.map(\.id) == ["newyork", "sanfrancisco", "london"])
        #expect(parse("Beijing Atlantis") != .meeting([]))
        // A two-word city is one place, not a meeting.
        if case .meeting = parse("hong kong") { Issue.record("hong kong is one city") }
    }

    @Test func `timestamps in seconds milliseconds and ISO 8601`() {
        let stamp = WorldClockFixtures.utc("2026-10-19T10:24:00Z")
        #expect(parse("1792405440") == .timestamp(stamp, .seconds))
        #expect(parse("1792405440000") == .timestamp(stamp, .milliseconds))
        #expect(parse("2026-10-19T10:24:00Z") == .timestamp(stamp, .iso))
        #expect(parse("2026-10-19 18:24:00+08:00") == .timestamp(stamp, .iso))
        #expect(parse("2026-10-19T10:24:00.000Z") == .timestamp(stamp, .iso))
        #expect(parse("now") == .timestamp(WorldClockFixtures.now, .now))
        #expect(parse("时间戳") == .timestamp(WorldClockFixtures.now, .now))
        if case .timestamp = parse("12345") { Issue.record("five digits are not a timestamp") }
    }
}

@Suite("World clock time words")
struct WorldClockTimeTextTests {
    private func time(_ text: String) -> String? {
        WorldClockTimeText.time(in: text).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
    }

    @Test func `chinese and english times`() {
        #expect(time("9:05") == "09:05")
        #expect(time("15：30") == "15:30")
        #expect(time("9am") == "09:00")
        #expect(time("9 p.m.") == "21:00")
        #expect(time("12am") == "00:00")
        #expect(time("12pm") == "12:00")
        #expect(time("上午12点") == "00:00")
        #expect(time("中午1点") == "13:00")
        #expect(time("中午12点") == "12:00")
        #expect(time("下午3点半") == "15:30")
        #expect(time("晚上8点") == "20:00")
        #expect(time("9点一刻") == "09:15")
        #expect(time("9点三刻") == "09:45")
        #expect(time("9点20分") == "09:20")
        #expect(time("下午15点") == "15:00")
        #expect(time("13pm") == nil)
        #expect(time("25:00") == nil)
        #expect(time("9:75") == nil)
        #expect(time("上午15点") == nil)
        #expect(time("london") == nil)
        #expect(WorldClockTimeText.time(in: "9am 纽约")?.rest.trimmingCharacters(in: .whitespaces) == "纽约")
    }

    @Test func `day words weekdays and dates`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WorldClockFixtures.shanghai
        func day(_ text: String) -> Date? {
            var rest = text
            return WorldClockTimeText.day(in: &rest).date(today: WorldClockFixtures.now, calendar: calendar)
        }
        func key(_ date: Date?) -> String? {
            date.map { calendar.dateComponents([.month, .day], from: $0) }.map { "\($0.month!)-\($0.day!)" }
        }
        #expect(key(day("")) == "10-22")
        #expect(key(day("明天")) == "10-23")
        #expect(key(day("后天")) == "10-24")
        #expect(key(day("大后天")) == "10-25")
        #expect(key(day("yesterday")) == "10-21")
        #expect(key(day("周四")) == "10-22")
        #expect(key(day("星期日")) == "10-25")
        #expect(key(day("下周一")) == "10-26")
        #expect(key(day("下下周三")) == "11-4")
        #expect(key(day("这周三")) == "10-21")
        #expect(key(day("本周六")) == "10-24")
        #expect(key(day("sunday")) == "10-25")
        #expect(key(day("next fri")) == "10-30")
        #expect(key(day("11/3")) == "11-3")
        #expect(key(day("2027.1.5")) == "1-5")
        #expect(day("2-30") == nil)
    }
}

@Suite("World city directory")
struct WorldCityDirectoryTests {
    let directory = WorldClockFixtures.directory

    @Test func `bundled table loads with every language`() {
        let cities = WorldCityDirectory.bundledCities()
        #expect(cities.count >= 140)
        for city in cities {
            #expect(AppLanguage.allCases.allSatisfy { city.names[$0.rawValue]?.isEmpty == false }, "\(city.id)")
        }
        #expect(Set(cities.map(\.id)).count == cities.count)
    }

    @Test func `system zones fill in places the table does not list`() throws {
        let thimphu = try #require(directory.city(id: "tz:Asia/Thimphu"))
        #expect(thimphu.timeZone.identifier == "Asia/Thimphu")
        #expect(directory.search("Thimphu").first?.id == "tz:Asia/Thimphu")
        // Tokyo is in the table, so the zone does not appear twice.
        #expect(!directory.cities.contains { $0.id == "tz:Asia/Tokyo" })
    }

    @Test func `stored ids rebuild offsets and zones`() {
        #expect(directory.city(id: "utc:+0530")?.timeZone.secondsFromGMT() == 19800)
        #expect(directory.city(id: "utc:-0300")?.name(in: .english) == "UTC−3")
        #expect(directory.city(id: "tz:Europe/Lisbon")?.timeZone.identifier == "Europe/Lisbon")
        #expect(directory.city(id: "utc:+9999") == nil)
        #expect(directory.city(id: "utc:x") == nil)
        #expect(directory.city(id: "tz:Mars/Base") == nil)
        #expect(directory.city(id: "nowhere") == nil)
        #expect(WorldClockCity.fixedOffset(minutes: 15 * 60) == nil)
    }

    @Test func `offsets pinyin and folding`() {
        #expect(WorldCityDirectory.offsetMinutes("utc") == 0)
        #expect(WorldCityDirectory.offsetMinutes("utc+8") == 480)
        #expect(WorldCityDirectory.offsetMinutes("gmt -5") == -300)
        #expect(WorldCityDirectory.offsetMinutes("utc+5:45") == 345)
        #expect(WorldCityDirectory.offsetMinutes("utc+5:75") == nil)
        #expect(WorldCityDirectory.offsetMinutes("utc+123") == nil)
        #expect(WorldCityDirectory.offsetMinutes("utcx") == nil)
        #expect(WorldCityDirectory.offsetMinutes("london") == nil)
        #expect(directory.resolve("UTC+15").isEmpty)
        #expect(WorldCityDirectory.pinyin("旧金山") == ["jiu", "jin", "shan"])
        #expect(WorldCityDirectory.pinyin("London").isEmpty)
        #expect(WorldCityDirectory.fold("  São   Paulo ") == "sao paulo")
        #expect(directory.search("").isEmpty && directory.resolve(" ").isEmpty)
    }

    @Test func `search ranks exact then prefix then contains, by population`() {
        let results = directory.search("san")
        #expect(results.contains { $0.id == "sanfrancisco" })
        let prefix = directory.search("Saint")
        #expect(prefix.first?.id == "saintpetersburg")
        #expect(directory.search("cisco").contains { $0.id == "sanfrancisco" })
        #expect(directory.search("新加坡").first?.id == "singapore")
        #expect(directory.representative(of: TimeZone(identifier: "America/New_York")!)?.id == "newyork")
        // The zone's own city, not the larger Chongqing that shares it.
        #expect(directory.representative(of: WorldClockFixtures.shanghai)?.id == "shanghai")
        // City names come before countries: "ban" is Bangalore and Bangkok before Bangladesh's Dhaka.
        let ban = directory.search("ban").map(\.id)
        #expect(ban.firstIndex(of: "bengaluru")! < ban.firstIndex(of: "dhaka")!)
        #expect(ban.firstIndex(of: "bangkok")! < ban.firstIndex(of: "dhaka")!)
    }

    @Test func `broken tables decode to nothing`() {
        #expect(WorldCityDirectory.decode(Data("{".utf8)).isEmpty)
        let bad = #"{"cities":[{"id":"x","tz":"Mars/Base","names":{"en":"X"}},{"id":"y","tz":"UTC","names":{}}]}"#
        #expect(WorldCityDirectory.decode(Data(bad.utf8)).isEmpty)
        #expect(WorldCityDirectory.bundledCities(bundle: Bundle(for: BundleToken.self)).isEmpty)
    }
}

private final class BundleToken {}
