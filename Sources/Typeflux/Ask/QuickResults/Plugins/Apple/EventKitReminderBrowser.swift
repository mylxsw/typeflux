import AppKit
import EventKit
import Foundation

/// Uses the native reminder store so searching does not traverse AppleScript object specifiers.
actor EventKitReminderBrowser: AppleProductivityBrowsing {
    private lazy var store = EKEventStore()

    private func checkAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { throw Failure.permissionRequired }
        if #available(macOS 14, *), status == .fullAccess { return }
        guard status == .authorized else { throw Failure.permissionDenied }
    }

    /// Only the explicit authorization action calls this, never live search.
    func requestAccess(kind: AskAppleProductivityPlugin.Kind) async throws {
        guard kind == .reminders else { throw Failure.unavailable }
        if (try? checkAccess()) != nil { return }
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (Bool, Error?) -> Void = { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
            if #available(macOS 14, *) { store.requestFullAccessToReminders(completion: completion) }
            else { store.requestAccess(to: .reminder, completion: completion) }
        }
        store.reset()
        guard granted else { throw Failure.permissionDenied }
    }

    func search(kind: AskAppleProductivityPlugin.Kind, query: String, includeCompleted: Bool) async throws -> AppleProductivityMatches {
        guard kind == .reminders, query.count <= 500 else { throw AppleProductivityBrowser.Failure.invalid }
        try checkAccess()
        try Task.checkCancellation()
        let predicate = includeCompleted ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let result: AppleProductivityMatches = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else { continuation.resume(throwing: Failure.unavailable); return }
                continuation.resume(returning: Self.matches(reminders, query: query, includeCompleted: includeCompleted))
            }
        }
        try Task.checkCancellation()
        return result
    }

    func read(kind: AskAppleProductivityPlugin.Kind, id: String) throws -> AppleProductivityItem {
        guard kind == .reminders else { throw Failure.unavailable }
        try checkAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AppleProductivityBrowser.Failure.missing
        }
        return Self.snapshot(reminder, includeBody: true)
    }

    func open(kind: AskAppleProductivityPlugin.Kind, id: String) async throws {
        _ = try read(kind: kind, id: id)
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-"))),
              let url = URL(string: "x-apple-reminderkit://REMCDReminder/" + encoded),
              await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw Failure.unavailable }
    }

    static func matches(_ reminders: [EKReminder], query: String, includeCompleted: Bool) -> AppleProductivityMatches {
        let selected = reminders.filter {
            (includeCompleted || !$0.isCompleted) && (query.isEmpty
                || ($0.title ?? "").localizedStandardContains(query) || ($0.notes ?? "").localizedStandardContains(query))
        }.sorted {
            let first = due($0) ?? .distantFuture, second = due($1) ?? .distantFuture
            return first == second ? ($0.title ?? "") < ($1.title ?? "") : first < second
        }
        return .init(items: selected.prefix(30).map { snapshot($0, includeBody: false) },
                     total: selected.count, hasMore: selected.count > 30)
    }

    static func snapshot(_ reminder: EKReminder, includeBody: Bool) -> AppleProductivityItem {
        let deadline = due(reminder)
        let text = includeBody ? reminder.notes ?? "" : ""
        let alarms = (reminder.alarms ?? []).compactMap { alarm in
            alarm.absoluteDate ?? deadline.map { $0.addingTimeInterval(alarm.relativeOffset) }
        }
        return .init(id: reminder.calendarItemIdentifier ?? "", title: reminder.title ?? "", container: reminder.calendar?.title ?? "",
                     modified: reminder.lastModifiedDate, due: deadline, alarm: alarms.min(), completed: reminder.isCompleted,
                     locked: false, body: String(text.prefix(50000)), truncated: text.count > 50000,
                     allDay: deadline != nil && reminder.dueDateComponents?.hour == nil)
    }

    private static func due(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return (components.calendar ?? Calendar.current).date(from: components)
    }

    enum Failure: Error { case permissionRequired, permissionDenied, unavailable }
}
