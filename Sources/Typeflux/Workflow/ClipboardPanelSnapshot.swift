import Foundation

/// A short-lived, in-memory opening snapshot. Store notifications invalidate it;
/// every use still starts a fresh background read. No content is persisted here.
struct ClipboardPanelSnapshot {
    let entries: [ClipboardEntry]
    let policy: String
    let store: ObjectIdentifier?
    let recordedUptime: TimeInterval
    let expiresAt: Date

    init(entries: [ClipboardEntry], policy: String, store: ObjectIdentifier?, retentionDays: Int?,
         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.entries = entries
        self.policy = policy
        self.store = store
        recordedUptime = uptime
        expiresAt = entries.compactMap { entry -> Date? in
            guard let retentionDays, !entry.isPinned, entry.snippet == nil,
                  case .clipboard = entry.origin else { return nil }
            return entry.date.addingTimeInterval(TimeInterval(retentionDays) * 86400)
        }.min() ?? .distantFuture
    }

    func isValid(policy: String, store: ObjectIdentifier?, now: Date = Date(),
                 uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        self.policy == policy && self.store == store && now < expiresAt &&
            uptime >= recordedUptime && uptime - recordedUptime < 30
    }
}
