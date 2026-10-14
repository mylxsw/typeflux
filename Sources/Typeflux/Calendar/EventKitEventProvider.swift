import AppKit
import EventKit
import Foundation

/// EventKit objects remain on this actor and only immutable snapshots reach the UI.
actor EventKitEventProvider: CalendarEventProviding {
    private let store = EKEventStore()
    private struct Cache {
        var start: Date
        var end: Date
        var calendars: Set<String>
        var events: [CalendarEvent]
    }

    private var cached: Cache?

    func access() -> CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            return .unknown
        }
        if #available(macOS 14, *), status == .fullAccess {
            return .allowed
        }
        return status == .authorized ? .allowed : .denied
    }

    /// Called only by the explicit permission button, never by loading the calendar.
    func requestAccess() async throws -> CalendarAccess {
        let allowed: Bool = try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (Bool, Error?) -> Void = { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
            if #available(macOS 14, *) {
                store.requestFullAccessToEvents(completion: completion)
            } else {
                store.requestAccess(to: .event, completion: completion)
            }
        }
        cached = nil
        return allowed ? .allowed : .denied
    }

    func sources() -> [CalendarSource] {
        guard access() == .allowed else { return [] }
        return store.calendars(for: .event).map(source)
    }

    func events(from start: Date, to end: Date, calendars ids: Set<String>) -> [CalendarEvent] {
        guard access() == .allowed, start < end else { return [] }
        if let cached, cached.start == start, cached.end == end, cached.calendars == ids {
            return cached.events
        }
        let calendars = store.calendars(for: .event).filter {
            ids.isEmpty ? !source($0).holiday : ids.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).map { event in
            CalendarEvent(
                id: (event.eventIdentifier ?? UUID().uuidString) + ":" + String(event.startDate.timeIntervalSince1970),
                externalID: event.calendarItemExternalIdentifier,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                allDay: event.isAllDay,
                location: event.location ?? "",
                notes: event.notes ?? "",
                attendees: event.attendees?.count,
                organizer: event.organizer?.name,
                url: event.url,
                calendar: source(event.calendar)
            )
        }
        cached = Cache(start: start, end: end, calendars: ids, events: events)
        return events
    }

    func invalidate() {
        cached = nil; store.reset()
    }

    private func source(_ calendar: EKCalendar) -> CalendarSource {
        let color = calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
        let hex = String(format: "%02X%02X%02X", Int((color?.redComponent ?? 0.3) * 255),
                         Int((color?.greenComponent ?? 0.6) * 255), Int((color?.blueComponent ?? 0.9) * 255))
        let holiday = calendar.type == .subscription && ["holiday", "节假日", "節假日", "节日", "節日", "祝日", "공휴일"].contains {
            calendar.title.localizedCaseInsensitiveContains($0)
        }
        return CalendarSource(id: calendar.calendarIdentifier, title: calendar.title, color: hex, holiday: holiday)
    }
}
