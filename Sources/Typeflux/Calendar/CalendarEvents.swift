import Foundation

enum CalendarAccess: Equatable, Sendable { case unknown, denied, allowed }

struct CalendarSource: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var color: String
    var holiday: Bool = false
}

struct CalendarEvent: Equatable, Sendable, Identifiable {
    var id: String
    var externalID: String?
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    var location: String = ""
    var notes: String = ""
    var attendees: Int?
    var organizer: String?
    var url: URL?
    var calendar: CalendarSource

    var meeting: URL? {
        MeetingLinkDetector.find(in: [url?.absoluteString ?? "", location, notes])
    }

    func occurs(on date: Date, dates: CalendarDates) -> Bool {
        let day = dates.calendar.startOfDay(for: date), next = dates.adding(1, to: day)
        return start < next && (end > day || (start == end && start >= day))
    }

    func matches(_ query: String) -> Bool {
        [title, location, calendar.title].contains { $0.localizedStandardContains(query) }
    }

    func copied(dates: CalendarDates, preferences: CalendarPreferences, locale: Locale) -> String {
        let date = preferences.copiedDate(start, dates: dates, locale: locale)
        let time = allDay ? "" : " " + dates.format(start, "HHmm", locale: locale)
            + "–" + dates.format(end, "HHmm", locale: locale)
        return title + ", " + date + time + (location.isEmpty ? "" : ", " + location)
    }

    static func sorted(_ events: [Self]) -> [Self] {
        events.sorted {
            if $0.allDay != $1.allDay {
                return $0.allDay
            }
            return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }
}

/// Only supported, exact domains or their subdomains may become meeting actions.
enum MeetingLinkDetector {
    static let domains = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                          "meeting.tencent.com", "vc.feishu.cn", "meetings.larkoffice.com"]

    static func find(in fields: [String]) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"\\[\\]]+", options: .caseInsensitive)
        else { return nil }
        for field in fields {
            for match in regex.matches(in: field, range: NSRange(field.startIndex..., in: field)) {
                guard let range = Range(match.range, in: field) else { continue }
                let text = String(field[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;，。；）"))
                guard let url = URL(string: text), let host = url.host?.lowercased(), url.user == nil,
                      url.password == nil,
                      domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                return url
            }
        }
        return nil
    }
}

protocol CalendarEventProviding: Sendable {
    func access() async -> CalendarAccess
    func requestAccess() async throws -> CalendarAccess
    func sources() async -> [CalendarSource]
    func events(from start: Date, to end: Date, calendars: Set<String>) async -> [CalendarEvent]
    func invalidate() async
}

enum CalendarLinks {
    static func day(_ date: Date) -> URL {
        URL(string: "ical://show/date=\(Int(date.timeIntervalSinceReferenceDate))")!
    }

    static func event(_ event: CalendarEvent) -> URL {
        guard let id = event.externalID, !id.isEmpty,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "ical://ekevent/" + encoded) else { return day(event.start) }
        return url
    }
}
