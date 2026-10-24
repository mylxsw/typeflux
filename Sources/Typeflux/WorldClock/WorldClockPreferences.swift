import Foundation

/// The world clock's settings, kept in its keyword's options like the calendar's.
struct WorldClockPreferences: Equatable, Sendable {
    enum HourFormat: String, CaseIterable, Sendable {
        case system, twentyFour = "24", twelve = "12"
    }

    enum CopyFormat: String, CaseIterable, Sendable {
        /// "New York Thu, Oct 22 06:24"
        case full
        /// "New York 06:24"
        case city
        /// "06:24"
        case time
        /// "2026-10-22T06:24:00-04:00"
        case iso
    }

    static let citiesOption = "worldclock.cities"
    static let labelsOption = "worldclock.labels"
    static let hourFormatOption = "worldclock.hourFormat"
    static let workStartOption = "worldclock.workStart"
    static let workEndOption = "worldclock.workEnd"
    static let workdaysOption = "worldclock.workdays"
    static let stepOption = "worldclock.step"
    static let hintCountOption = "worldclock.hintCount"
    static let copyFormatOption = "worldclock.copyFormat"
    static let meetingZonesOption = "worldclock.meetingZones"

    /// Cities after the local one, in the user's order.
    var cityIDs: [String]
    /// The note after a city's name ("Maya"), by city id.
    var labels: [String: String]
    var hourFormat: HourFormat
    /// Minutes after midnight.
    var workStart: Int
    var workEnd: Int
    /// `Calendar` weekdays: 1 is Sunday.
    var workdays: Set<Int>
    /// Minutes ←→ moves the time.
    var step: Int
    /// How many cities the keyword's hint row shows after the local time.
    var hintCount: Int
    var copyFormat: CopyFormat
    /// Meeting times copied with zone abbreviations ("09:00 EDT").
    var meetingAbbreviations: Bool

    /// First-use cities and their zones; the zones are spelled out so defaults never load the city table.
    static let defaultCities: [(id: String, zone: String)] = [
        ("utc:+0000", "GMT"),
        ("sanfrancisco", "America/Los_Angeles"), ("newyork", "America/New_York"), ("london", "Europe/London"),
        ("berlin", "Europe/Berlin"), ("mumbai", "Asia/Kolkata"), ("beijing", "Asia/Shanghai"),
        ("tokyo", "Asia/Tokyo"), ("sydney", "Australia/Sydney")
    ]
    static let steps = [15, 30, 60]

    init(options: [String: String] = [:], localZone: TimeZone = .current) {
        if let stored = options[Self.citiesOption].flatMap(Self.decodeList) {
            cityIDs = stored
        } else {
            // The local zone is already the first row; leave its city out.
            cityIDs = Self.defaultCities.filter { $0.zone != localZone.identifier }.map(\.id)
        }
        labels = options[Self.labelsOption].flatMap(Self.decodeLabels) ?? [:]
        hourFormat = options[Self.hourFormatOption].flatMap(HourFormat.init(rawValue:)) ?? .system
        let start = options[Self.workStartOption].flatMap(Int.init) ?? 9 * 60
        let end = options[Self.workEndOption].flatMap(Int.init) ?? 18 * 60
        if (0 ..< 24 * 60).contains(start), (1 ... 24 * 60).contains(end), start < end {
            workStart = start
            workEnd = end
        } else {
            workStart = 9 * 60
            workEnd = 18 * 60
        }
        let days = Set((options[Self.workdaysOption] ?? "2,3,4,5,6").split(separator: ",")
            .compactMap { Int($0) }.filter { (1 ... 7).contains($0) })
        workdays = options[Self.workdaysOption] == nil ? [2, 3, 4, 5, 6] : days
        step = options[Self.stepOption].flatMap(Int.init).flatMap { Self.steps.contains($0) ? $0 : nil } ?? 30
        hintCount = options[Self.hintCountOption].flatMap(Int.init).map { max(0, min(6, $0)) } ?? 4
        copyFormat = options[Self.copyFormatOption].flatMap(CopyFormat.init(rawValue:)) ?? .full
        meetingAbbreviations = options[Self.meetingZonesOption] != "false"
    }

    /// Writes every setting the editor shows; options it does not know are kept.
    func write(into options: inout [String: String]) {
        options[Self.citiesOption] = Self.encode(cityIDs)
        options[Self.labelsOption] = labels.isEmpty ? nil : Self.encode(labels)
        options[Self.hourFormatOption] = hourFormat == .system ? nil : hourFormat.rawValue
        options[Self.workStartOption] = workStart == 9 * 60 ? nil : String(workStart)
        options[Self.workEndOption] = workEnd == 18 * 60 ? nil : String(workEnd)
        options[Self.workdaysOption] = workdays == [2, 3, 4, 5, 6] ? nil
            : workdays.sorted().map(String.init).joined(separator: ",")
        options[Self.stepOption] = step == 30 ? nil : String(step)
        options[Self.hintCountOption] = hintCount == 4 ? nil : String(hintCount)
        options[Self.copyFormatOption] = copyFormat == .full ? nil : copyFormat.rawValue
        options[Self.meetingZonesOption] = meetingAbbreviations ? nil : "false"
    }

    /// Whether times read "18:24" rather than "6:24 PM".
    func uses24Hour(locale: Locale = .current) -> Bool {
        switch hourFormat {
        case .twentyFour: true
        case .twelve: false
        case .system: !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "H").contains("a")
        }
    }

    func label(for id: String) -> String? {
        labels[id].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    private static func decodeList(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private static func decodeLabels(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
