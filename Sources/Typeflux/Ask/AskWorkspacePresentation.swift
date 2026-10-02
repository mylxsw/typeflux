import Foundation

/// The state dot beside the conversation title in the header capsule.
enum AskRunTone: Equatable {
    case done, running, attention, failed

    static func of(_ run: AskRun?, pendingApproval: Bool) -> AskRunTone? {
        guard let run else { return nil }
        if pendingApproval { return .attention }
        if run.isActive { return .running }
        switch run.status {
        case "completed": return .done
        case "failed", "cancelled": return .failed
        default: return nil
        }
    }
}

/// What the composer's send control does right now. While a run works, an
/// empty composer offers Stop in the same place; once something is typed the
/// control sends again, and the follow-up is queued behind the run.
enum AskSendControl: Equatable {
    case send(enabled: Bool)
    case stop

    static func resolve(busy: Bool, hasDraft: Bool, canSend: Bool, editingQueued: Bool) -> AskSendControl {
        if busy, !hasDraft, !editingQueued { return .stop }
        return .send(enabled: canSend)
    }
}

extension AskPresentation {
    /// The trailing label of a history row: the time for today and yesterday
    /// (their group header already names the day), the date for anything older.
    static func historyTimeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                 locale: Locale = AppLocalization.shared.locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let startOfToday = calendar.startOfDay(for: now)
        let recent = calendar.date(byAdding: .day, value: -1, to: startOfToday).map { date >= $0 } ?? false
        if recent {
            formatter.setLocalizedDateFormatFromTemplate("jjmm")
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        }
        return formatter.string(from: date)
    }
}
