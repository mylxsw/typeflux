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
    /// The server paused the run until the account has credits again.
    case pausedCredits(step: Int)
    case waitingDevice(step: Int)
    case endedWithPendingPlan
    case completed(steps: Int)
    case failed
    case cancelled

    /// `busy` means a local operation is driving the conversation right now.
    static func resolve(run: AskRun?, busy: Bool, pendingApproval: Bool,
                        recovery: AskRecoveryPresentation?) -> AskRunPhase? {
        let step = max(run?.steps ?? 0, 1)
        // The host owns inspection now; it is work in progress, not a request
        // for the user to troubleshoot an old receipt. Keep Stop available.
        if busy, run?.internalRecovery?.phase == .inspecting {
            return pendingApproval ? .approval : .working(step: step)
        }
        // Otherwise an unknown outcome blocks normal execution.
        let inspectionBlocked = run.map { $0.isActive && $0.needsRecoveryInspection } ?? false
        if run != nil, recovery?.unknown == true || inspectionBlocked || (recovery?.savedReceipts ?? 0) > 0 {
            return .needsDecision(step: step)
        }
        if pendingApproval, let run, !run.needsRecoveryInspection { return .approval }
        if let run, run.isPausedForCredits { return .pausedCredits(step: step) }
        if let run, recovery?.otherDevice == true, ["waiting_tool", "waiting_inference"].contains(run.status) {
            return .waitingDevice(step: step)
        }
        if busy { return .working(step: step) }
        guard let run else { return nil }
        // The recovery card only appears while nothing drives the run.
        if recovery?.isVisible == true { return .needsDecision(step: step) }
        if run.isActive { return .working(step: step) }
        switch run.status {
        case "completed":
            if run.plan?.contains(where: { $0.status != "completed" }) == true { return .endedWithPendingPlan }
            return .completed(steps: run.steps)
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
        case .working, .approval, .pausedCredits: return true
        default: return false
        }
    }

    /// The step shown by both the header and the live activity line.
    var step: Int? {
        switch self {
        case let .working(step), let .needsDecision(step), let .pausedCredits(step), let .waitingDevice(step): return step
        default: return nil
        }
    }

    var tone: AskRunTone {
        switch self {
        case .working: return .running
        case .approval, .needsDecision, .pausedCredits, .waitingDevice, .endedWithPendingPlan: return .attention
        case .completed: return .done
        case .failed, .cancelled: return .failed
        }
    }

    var summary: String {
        switch self {
        case let .working(step): return L("ask.run.running", step)
        case .approval: return L("ask.run.attention")
        case .needsDecision: return L("ask.run.needsDecision")
        case .pausedCredits: return L("ask.run.pausedCredits")
        case .waitingDevice: return L("ask.recovery.otherDevice")
        case .endedWithPendingPlan: return L("ask.run.endedWithPendingPlan")
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
