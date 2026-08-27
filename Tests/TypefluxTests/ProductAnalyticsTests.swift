import XCTest
@testable import Typeflux

final class ProductAnalyticsTests: XCTestCase {
    func testP0AnalyticsPropertiesAreAllowlisted() {
        let required: Set<String> = [
            "launch_type", "flow_id", "recording_mode", "intent", "stt_provider", "local_model",
            "streaming_preview", "audio_seconds", "output_chars", "pipeline_duration_ms", "apply_outcome",
            "injection_method", "target_app_category", "stage", "error_kind", "step", "last_step", "skipped",
            "duration_seconds", "llm_provider", "permission", "granted", "totalSessions", "successfulSessions",
            "failedSessions", "dictationCount", "personaRewriteCount", "editSelectionCount", "askAnswerCount",
            "totalRecordingSeconds", "totalCharacters"
        ]

        XCTAssertTrue(required.isSubset(of: AnalyticsPropertyKeys.allowedEventProperties))
        XCTAssertFalse(AnalyticsPropertyKeys.allowedEventProperties.contains("transcript"))
        XCTAssertFalse(AnalyticsPropertyKeys.allowedEventProperties.contains("bundle_id"))
        XCTAssertFalse(AnalyticsPropertyKeys.allowedEventProperties.contains("error_message"))
    }

    func testTargetAppCategoryDoesNotExposeApplicationIdentity() {
        XCTAssertEqual(AnalyticsTargetAppCategory.classify(bundleIdentifier: "com.apple.dt.Xcode"), .coding)
        XCTAssertEqual(AnalyticsTargetAppCategory.classify(bundleIdentifier: "com.google.Chrome"), .browser)
        XCTAssertEqual(AnalyticsTargetAppCategory.classify(bundleIdentifier: "com.microsoft.Word"), .office)
        XCTAssertEqual(AnalyticsTargetAppCategory.classify(bundleIdentifier: "com.example.private-app"), .other)
        XCTAssertEqual(AnalyticsTargetAppCategory.classify(bundleIdentifier: nil), .other)
    }

    func testDailySummaryBaselinesThenReportsOnlyOncePerNewDay() throws {
        let suite = "ProductAnalyticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = AnalyticsEventRecorder()
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T08:00:00Z"))
        let reporter = UsageDailySummaryReporter(defaults: defaults, reporter: recorder, now: { now })
        let baseline = snapshot(total: 10, successful: 8, failed: 2, seconds: 12.5, characters: 100)

        reporter.reportIfNeeded(snapshot: baseline)
        reporter.reportIfNeeded(snapshot: snapshot(total: 11, successful: 9, failed: 2, seconds: 14, characters: 120))
        XCTAssertTrue(recorder.events.isEmpty)

        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-27T08:00:00Z"))
        reporter.reportIfNeeded(snapshot: snapshot(total: 13, successful: 10, failed: 3, seconds: 18, characters: 160))
        reporter.reportIfNeeded(snapshot: snapshot(total: 14, successful: 11, failed: 3, seconds: 20, characters: 180))

        let event = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(event.name, "usage_daily_summary")
        XCTAssertEqual(event.properties["totalSessions"], "3")
        XCTAssertEqual(event.properties["successfulSessions"], "2")
        XCTAssertEqual(event.properties["failedSessions"], "1")
        XCTAssertEqual(event.properties["totalRecordingSeconds"], "5.500")
        XCTAssertEqual(event.properties["totalCharacters"], "60")
    }

    func testUsageSnapshotReadsOverviewCountersFromUsageStatsStore() throws {
        let suite = "UsageSnapshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9, forKey: "stats.totalSessions")
        defaults.set(7, forKey: "stats.successfulSessions")
        defaults.set(2, forKey: "stats.failedSessions")
        defaults.set(3, forKey: "stats.dictationCount")
        defaults.set(2, forKey: "stats.personaRewriteCount")
        defaults.set(1, forKey: "stats.editSelectionCount")
        defaults.set(3, forKey: "stats.askAnswerCount")
        defaults.set(12.5, forKey: "stats.totalRecordingSeconds")
        defaults.set(150, forKey: "stats.totalCharacters")

        let actual = UsageStatsAnalyticsSnapshot.current(from: UsageStatsStore(defaults: defaults))

        XCTAssertEqual(actual, snapshot(
            total: 9,
            successful: 7,
            failed: 2,
            seconds: 12.5,
            characters: 150,
            dictation: 3,
            personaRewrite: 2,
            editSelection: 1,
            askAnswer: 3
        ))
    }

    @MainActor
    func testPermissionMonitorBaselinesAndReportsOnlyFlips() throws {
        let suite = "PermissionAnalyticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = AnalyticsEventRecorder()
        let monitor = PermissionStatusAnalyticsMonitor(defaults: defaults, reporter: recorder)
        let denied = PrivacyGuard.PermissionSnapshot(
            id: .microphone,
            state: .needsAttention,
            detail: "denied"
        )
        let granted = PrivacyGuard.PermissionSnapshot(id: .microphone, state: .granted, detail: "granted")

        monitor.observe([denied])
        monitor.observe([denied])
        XCTAssertTrue(recorder.events.isEmpty)

        monitor.observe([granted])
        monitor.observe([granted])

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events[0].name, "permission_status")
        XCTAssertEqual(recorder.events[0].properties, ["permission": "microphone", "granted": "true"])
    }

    @MainActor
    func testPermissionMonitorCanPollSystemStatusesWithoutDuplicateEvents() throws {
        let suite = "PermissionSystemStatusTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = AnalyticsEventRecorder()
        let monitor = PermissionStatusAnalyticsMonitor(defaults: defaults, reporter: recorder)

        monitor.observeCurrentStatuses()
        monitor.observeCurrentStatuses()

        XCTAssertTrue(recorder.events.isEmpty)
    }

    private func snapshot(
        total: Int,
        successful: Int,
        failed: Int,
        seconds: Double,
        characters: Int,
        dictation: Int? = nil,
        personaRewrite: Int = 0,
        editSelection: Int = 0,
        askAnswer: Int = 0
    ) -> UsageStatsAnalyticsSnapshot {
        UsageStatsAnalyticsSnapshot(
            totalSessions: total,
            successfulSessions: successful,
            failedSessions: failed,
            dictationCount: dictation ?? successful,
            personaRewriteCount: personaRewrite,
            editSelectionCount: editSelection,
            askAnswerCount: askAnswer,
            totalRecordingSeconds: seconds,
            totalCharacters: characters
        )
    }
}

final class AnalyticsEventRecorder: AnalyticsEventReporting, @unchecked Sendable {
    struct Event {
        let name: String
        let properties: [String: String]
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []

    var events: [Event] { lock.withLock { storedEvents } }

    func report(eventName: String, properties: [String: String]) {
        lock.withLock { storedEvents.append(Event(name: eventName, properties: properties)) }
    }

    func reportFirstOpenIfNeeded() {}
}
