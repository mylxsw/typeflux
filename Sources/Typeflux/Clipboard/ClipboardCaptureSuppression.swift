import Foundation

/// Marks moments when Typeflux itself drives the pasteboard (sending ⌘C to read a selection,
/// then restoring the user's clipboard), so the clipboard history does not record them.
///
/// Changes seen while suppressed, or within `gracePeriod` after it ends, are skipped. The grace
/// period covers a restore that was skipped because the clipboard changed mid-probe.
final class ClipboardCaptureSuppression {
    static let shared = ClipboardCaptureSuppression()

    let gracePeriod: TimeInterval
    private let uptime: () -> TimeInterval
    private let lock = NSLock()
    private var activeCount = 0
    private var lastEndedAt: TimeInterval?

    init(gracePeriod: TimeInterval = 1.0, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.gracePeriod = gracePeriod
        self.uptime = uptime
    }

    func begin() {
        lock.withLock { activeCount += 1 }
    }

    func end() {
        lock.withLock {
            activeCount = max(0, activeCount - 1)
            lastEndedAt = uptime()
        }
    }

    var isSuppressed: Bool {
        lock.withLock {
            if activeCount > 0 { return true }
            guard let lastEndedAt else { return false }
            return uptime() - lastEndedAt < gracePeriod
        }
    }
}
