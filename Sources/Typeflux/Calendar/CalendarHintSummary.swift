import SwiftUI

/// The hint reads events only when access was already granted.
struct CalendarHintSummary: View {
    var options: [String: String]
    var provider: (any CalendarEventProviding)?
    @State private var agenda = ""

    var body: some View {
        Text(AskCalendarPlugin.summary(language: AppLocalization.shared.language) + agenda)
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            .task {
                let preferences = CalendarPreferences(options: options, language: AppLocalization.shared.language)
                guard preferences.showsEvents, let provider, await provider.access() == .allowed else { return }
                await provider.invalidate()
                let dates = CalendarDates(), now = Date()
                let start = dates.calendar.startOfDay(for: now)
                let sources = await provider.sources()
                let events = await provider.events(
                    from: start,
                    to: dates.adding(1, to: start),
                    calendars: preferences.includedCalendars(sources)
                )
                guard !Task.isCancelled else { return }
                agenda = Self.eventSummary(events, now: now, dates: dates)
            }
    }

    static func eventSummary(_ events: [CalendarEvent], now: Date, dates: CalendarDates) -> String {
        guard !events.isEmpty else { return "" }
        let next = events.filter { !$0.allDay && $0.start > now }.min { $0.start < $1.start }
        return " · " + L("calendar.eventCount", events.count) + (next.map {
            " · " + L("calendar.nextEvent", dates.format($0.start, "HHmm"), $0.title)
        } ?? "")
    }
}
