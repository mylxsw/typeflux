import Foundation

enum AnalyticsTargetAppCategory: String {
    case coding
    case office
    case browser
    case other

    static func classify(bundleIdentifier: String?) -> Self {
        guard let trimmedIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines), !trimmedIdentifier.isEmpty
        else { return .other }

        if CodingAppDetector.isCodingApp(bundleIdentifier: trimmedIdentifier) { return .coding }
        let identifier = trimmedIdentifier.lowercased()
        if browserBundleIdentifiers.contains(identifier) { return .browser }
        if officeBundleIdentifiers.contains(identifier) { return .office }
        return .other
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.safari", "com.google.chrome", "com.google.chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.microsoft.edgemac",
        "com.brave.browser", "company.thebrowser.browser", "com.operasoftware.opera"
    ]

    private static let officeBundleIdentifiers: Set<String> = [
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote",
        "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
        "com.microsoft.outlook", "com.apple.mail", "com.apple.notes"
    ]
}

struct UsageStatsAnalyticsSnapshot: Codable, Equatable {
    var totalSessions: Int
    var successfulSessions: Int
    var failedSessions: Int
    var dictationCount: Int
    var personaRewriteCount: Int
    var editSelectionCount: Int
    var askAnswerCount: Int
    var totalRecordingSeconds: Double
    var totalCharacters: Int

    static func current(from store: UsageStatsStore) -> Self {
        Self(
            totalSessions: store.totalSessions,
            successfulSessions: store.successfulSessions,
            failedSessions: store.failedSessions,
            dictationCount: store.dictationCount,
            personaRewriteCount: store.personaRewriteCount,
            editSelectionCount: store.editSelectionCount,
            askAnswerCount: store.askAnswerCount,
            totalRecordingSeconds: store.totalRecordingSeconds,
            totalCharacters: store.totalCharacterCount
        )
    }

    func nonnegativeDelta(from previous: Self) -> Self {
        Self(
            totalSessions: max(0, totalSessions - previous.totalSessions),
            successfulSessions: max(0, successfulSessions - previous.successfulSessions),
            failedSessions: max(0, failedSessions - previous.failedSessions),
            dictationCount: max(0, dictationCount - previous.dictationCount),
            personaRewriteCount: max(0, personaRewriteCount - previous.personaRewriteCount),
            editSelectionCount: max(0, editSelectionCount - previous.editSelectionCount),
            askAnswerCount: max(0, askAnswerCount - previous.askAnswerCount),
            totalRecordingSeconds: max(0, totalRecordingSeconds - previous.totalRecordingSeconds),
            totalCharacters: max(0, totalCharacters - previous.totalCharacters)
        )
    }

    var properties: [String: String] {
        [
            "totalSessions": "\(totalSessions)",
            "successfulSessions": "\(successfulSessions)",
            "failedSessions": "\(failedSessions)",
            "dictationCount": "\(dictationCount)",
            "personaRewriteCount": "\(personaRewriteCount)",
            "editSelectionCount": "\(editSelectionCount)",
            "askAnswerCount": "\(askAnswerCount)",
            "totalRecordingSeconds": String(format: "%.3f", totalRecordingSeconds),
            "totalCharacters": "\(totalCharacters)"
        ]
    }
}

final class UsageDailySummaryReporter {
    private let defaults: UserDefaults
    private let reporter: AnalyticsEventReporting
    private let calendar: Calendar
    private let now: () -> Date
    private let snapshotKey: String
    private let dayKey: String

    init(
        defaults: UserDefaults,
        reporter: AnalyticsEventReporting,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() },
        snapshotKey: String = "analytics.usageDailySummary.snapshot",
        dayKey: String = "analytics.usageDailySummary.day"
    ) {
        self.defaults = defaults
        self.reporter = reporter
        self.calendar = calendar
        self.now = now
        self.snapshotKey = snapshotKey
        self.dayKey = dayKey
    }

    func reportIfNeeded(snapshot: UsageStatsAnalyticsSnapshot) {
        let today = calendar.startOfDay(for: now())
        if let lastDay = defaults.object(forKey: dayKey) as? Date,
           calendar.isDate(lastDay, inSameDayAs: today) {
            return
        }

        defer {
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: snapshotKey) }
            defaults.set(today, forKey: dayKey)
        }

        guard let data = defaults.data(forKey: snapshotKey),
              let previous = try? JSONDecoder().decode(UsageStatsAnalyticsSnapshot.self, from: data)
        else { return }

        reporter.report(
            eventName: "usage_daily_summary",
            properties: snapshot.nonnegativeDelta(from: previous).properties
        )
    }
}

@MainActor
final class PermissionStatusAnalyticsMonitor {
    private let defaults: UserDefaults
    private let reporter: AnalyticsEventReporting
    private let keyPrefix: String

    init(
        defaults: UserDefaults,
        reporter: AnalyticsEventReporting,
        keyPrefix: String = "analytics.permissionStatus."
    ) {
        self.defaults = defaults
        self.reporter = reporter
        self.keyPrefix = keyPrefix
    }

    func observeCurrentStatuses() {
        observe(PrivacyGuard.snapshots())
    }

    func observe(_ snapshots: [PrivacyGuard.PermissionSnapshot]) {
        for snapshot in snapshots {
            let key = keyPrefix + snapshot.id.rawValue
            let granted = snapshot.isGranted
            if defaults.object(forKey: key) != nil,
               defaults.bool(forKey: key) != granted {
                reporter.report(
                    eventName: "permission_status",
                    properties: [
                        "permission": snapshot.id.rawValue,
                        "granted": "\(granted)"
                    ]
                )
            }
            defaults.set(granted, forKey: key)
        }
    }
}
