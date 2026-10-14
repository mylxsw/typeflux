import Foundation

struct CalendarPreferences: Equatable, Sendable {
    var showsLunar: Bool
    var showsHolidays: Bool
    var showsWeeks: Bool
    var showsEvents: Bool
    var calendars: Set<String>
    var copyFormat: String

    init(
        options: [String: String] = [:],
        language: AppLanguage = .english,
        region: String? = Locale.current.region?.identifier
    ) {
        let chinese = language == .simplifiedChinese || language == .traditionalChinese || region == "CN"
        showsLunar = options["calendar.lunar"].map { $0 == "true" } ?? chinese
        showsHolidays = options["calendar.holidays"].map { $0 == "true" } ?? chinese
        showsWeeks = options["calendar.weeks"] == "true"
        showsEvents = options["calendar.events"] != "false"
        calendars = Set((options["calendar.calendars"] ?? "").split(separator: ",").map(String.init))
        copyFormat = options["calendar.copyFormat"] ?? "full"
    }

    func includedCalendars(_ sources: [CalendarSource]) -> Set<String> {
        if !calendars.isEmpty {
            return calendars
        }
        let eligible = sources.filter { !showsHolidays || !$0.holiday }.map(\.id)
        return eligible.isEmpty ? ["none"] : Set(eligible)
    }

    func copiedDate(_ date: Date, dates: CalendarDates, locale: Locale) -> String {
        switch copyFormat {
        case "iso": dates.key(date)
        case "short": dates.format(date, "MMMd", locale: locale)
        case "system": dates.format(date, "yMMMMEEEEd", locale: .current)
        default: dates.format(date, "yMMMEd", locale: locale)
        }
    }
}
