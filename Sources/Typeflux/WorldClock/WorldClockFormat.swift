import Foundation

/// The world clock's text: times, dates, offsets and durations.
enum WorldClockFormat {
    /// "UTC", "UTC+8", "UTC−4", "UTC+5:30".
    static func utcOffset(seconds: Int) -> String {
        guard seconds != 0 else { return "UTC" }
        let minutes = abs(seconds) / 60
        let sign = seconds < 0 ? "−" : "+"
        return "UTC" + sign + String(minutes / 60) + (minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60))
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// "18:24", or "6:24 PM" in the locale's own words.
    static func time(_ date: Date, in zone: TimeZone, uses24Hour: Bool, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateFormat = uses24Hour ? "HH:mm"
            : DateFormatter.dateFormat(fromTemplate: "hmma", options: 0, locale: locale) ?? "h:mm a"
        return formatter.string(from: date)
    }

    /// "10月22日 周四", "Thu, Oct 22".
    static func day(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter.string(from: date)
    }

    /// "周四", "Thu".
    static func weekday(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    /// "2026-10-22T06:24:00-04:00".
    static func iso(_ date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// "12 hours", "2 h 30 min", "45 min".
    static func duration(minutes: Int) -> String {
        let minutes = abs(minutes)
        if minutes >= 60, minutes % 60 == 0 { return L("worldclock.duration.hours", minutes / 60) }
        if minutes >= 60 { return L("worldclock.duration.hoursMinutes", minutes / 60, minutes % 60) }
        return L("worldclock.duration.minutes", minutes)
    }

    /// "12 hours behind Beijing", "Same time as Beijing".
    static func difference(seconds: Int, from place: String) -> String {
        let minutes = seconds / 60
        if minutes == 0 { return L("worldclock.diff.same", place) }
        return L(minutes < 0 ? "worldclock.diff.behind" : "worldclock.diff.ahead", place, duration(minutes: minutes))
    }

    /// "In 2 h 36 min", "3 days ago", "Now".
    static func relative(_ date: Date, to now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes == 0 { return L("worldclock.now") }
        let size = abs(minutes)
        let text: String
        if size >= 1440 {
            let days = size / 1440, hours = size % 1440 / 60
            text = hours == 0 ? L("worldclock.duration.days", days) : L("worldclock.duration.daysHours", days, hours)
        } else {
            text = duration(minutes: size)
        }
        return L(minutes > 0 ? "worldclock.relative.future" : "worldclock.relative.past", text)
    }

    /// Calendar days from `reference`'s date to `date`'s date, each read in its own zone.
    static func dayDelta(_ date: Date, in zone: TimeZone, from reference: Date, in referenceZone: TimeZone) -> Int {
        let here = calendar(zone).dateComponents([.year, .month, .day], from: date)
        let there = calendar(referenceZone).dateComponents([.year, .month, .day], from: reference)
        let utc = calendar(TimeZone(identifier: "UTC") ?? .gmt)
        guard let first = utc.date(from: there), let second = utc.date(from: here) else { return 0 }
        return utc.dateComponents([.day], from: first, to: second).day ?? 0
    }

    /// "Today", "Tomorrow", "Yesterday", or the date further away ("Oct 19"); the weekday follows separately.
    static func dayWord(delta: Int, date: Date, in zone: TimeZone, locale: Locale) -> String {
        switch delta {
        case 0: return L("worldclock.today")
        case 1: return L("worldclock.tomorrow")
        case -1: return L("worldclock.yesterday")
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return formatter.string(from: date)
        }
    }
}
