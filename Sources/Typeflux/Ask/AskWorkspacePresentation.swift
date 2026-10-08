import Foundation

/// The state dot beside the conversation title in the header capsule; see `AskRunPhase.tone`.
enum AskRunTone: Equatable {
    case done, running, attention, failed
}

/// The selected run's state, resolved once. The header's dot and summary, the
/// live activity line, its step count, its spinner and the composer's stop
/// control all read this value, so they can never disagree: a run that waits
/// for a recovery decision stops spinning everywhere at once.
enum AskRunPhase: Equatable {
    /// Something is driving the run; `step` is the run's own step count.
    case working(step: Int)
    /// A tool call waits for the user's approval.
    case approval
    /// The run stopped where only the user can decide what happens next.
    case needsDecision(step: Int)
    case completed(steps: Int)
    case failed
    case cancelled

    /// `busy` means a local operation is driving the conversation right now.
    static func resolve(run: AskRun?, busy: Bool, pendingApproval: Bool,
                        recovery: AskRecoveryPresentation?) -> AskRunPhase? {
        let step = max(run?.steps ?? 0, 1)
        // An unknown outcome blocks every driver, so nothing is actually working.
        if recovery?.unknown == true, run != nil { return .needsDecision(step: step) }
        if pendingApproval, let run, !run.needsRecoveryInspection { return .approval }
        if busy { return .working(step: step) }
        guard let run else { return nil }
        // The recovery card only appears while nothing drives the run.
        if recovery?.isVisible == true { return .needsDecision(step: step) }
        if run.isActive { return .working(step: step) }
        switch run.status {
        case "completed": return .completed(steps: run.steps)
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Spinners, shimmer and the composer's stop control show only while working.
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// The composer offers Stop while something holds the run open: working, or
    /// waiting on an approval. A recovery decision has its own Stop on the card.
    var offersStop: Bool {
        switch self {
        case .working, .approval: return true
        default: return false
        }
    }

    /// The step shown by both the header and the live activity line.
    var step: Int? {
        switch self {
        case let .working(step), let .needsDecision(step): return step
        default: return nil
        }
    }

    var tone: AskRunTone {
        switch self {
        case .working: return .running
        case .approval, .needsDecision: return .attention
        case .completed: return .done
        case .failed, .cancelled: return .failed
        }
    }

    var summary: String {
        switch self {
        case let .working(step): return L("ask.run.running", step)
        case .approval: return L("ask.run.attention")
        case .needsDecision: return L("ask.run.needsDecision")
        case let .completed(steps): return L("ask.run.completed", steps)
        case .failed: return L("ask.run.failed")
        case .cancelled: return L("ask.run.cancelled")
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
