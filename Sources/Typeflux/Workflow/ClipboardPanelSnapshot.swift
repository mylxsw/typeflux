import Foundation

/// An in-memory opening snapshot. Store notifications invalidate it;
/// every use still starts a fresh background read. No content is persisted here.
struct ClipboardPanelSnapshot {
    let entries: [ClipboardEntry]
    let policy: String
    let store: ObjectIdentifier?
    let recordedUptime: TimeInterval
    let expiresAt: Date

    init(entries: [ClipboardEntry], policy: String, store: ObjectIdentifier?, retentionDays: Int?, voiceRetentionDays: Int? = nil,
         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.entries = entries
        self.policy = policy
        self.store = store
        recordedUptime = uptime
        expiresAt = entries.compactMap { entry -> Date? in
            let days: Int?
            switch entry.origin {
            case .voice: days = voiceRetentionDays
            case .clipboard: days = !entry.isPinned && entry.snippet == nil ? retentionDays : nil
            }
            return days.map { entry.date.addingTimeInterval(TimeInterval($0) * 86400) }
        }.min() ?? .distantFuture
    }

    func isValid(policy: String, store: ObjectIdentifier?, now: Date = Date(),
                 uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        self.policy == policy && self.store == store && now < expiresAt && uptime >= recordedUptime
    }
}
