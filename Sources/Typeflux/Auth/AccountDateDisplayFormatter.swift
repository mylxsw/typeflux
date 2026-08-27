import Foundation

enum AccountDateDisplayFormatter {
    static func date(_ value: String, locale: Locale, timeZone: TimeZone = .current) -> String {
        guard let date = ISO8601DateFormatter.typefluxBillingDate(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func relativeTime(since date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        // A clock correction must not describe a completed sync as happening in the future.
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
