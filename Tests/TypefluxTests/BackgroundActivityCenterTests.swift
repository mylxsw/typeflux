import Combine
@testable import Typeflux
import XCTest

@MainActor
final class BackgroundActivityCenterTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        suiteNames.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        super.tearDown()
    }

    // MARK: - Model

    func testSortingPutsUserNeedsFirstThenRunningThenResting() {
        let sorted = BackgroundActivity.sorted([
            makeActivity("waiting", state: .waiting),
            makeActivity("index", kind: .index),
            makeActivity("paused", state: .paused),
            makeActivity("agent", kind: .agent),
            makeActivity("failed", state: .failed),
            makeActivity("download", kind: .download),
            makeActivity("attention", kind: .agent, state: .attention)
        ])

        XCTAssertEqual(sorted.map(\.id), ["attention", "failed", "agent", "download", "index", "paused", "waiting"])
    }

    func testSortingKeepsReportedOrderWithinTheSameRankAndKind() {
        let sorted = BackgroundActivity.sorted([makeActivity("b"), makeActivity("a"), makeActivity("c")])
        XCTAssertEqual(sorted.map(\.id), ["b", "a", "c"])
    }

    func testActivityFlagsFollowState() {
        XCTAssertTrue(makeActivity("a", state: .attention).isActive)
        XCTAssertTrue(makeActivity("a", state: .attention).needsUser)
        XCTAssertFalse(makeActivity("a", state: .attention).showsProgress)
        XCTAssertFalse(makeActivity("f", state: .failed).isActive)
        XCTAssertTrue(makeActivity("f", state: .failed).needsUser)
        XCTAssertTrue(makeActivity("r").isActive)
        XCTAssertTrue(makeActivity("r").showsProgress)
        XCTAssertFalse(makeActivity("p", state: .paused).isActive)
        XCTAssertTrue(makeActivity("p", state: .paused).showsProgress)
        XCTAssertTrue(makeActivity("w", state: .waiting).showsProgress)
    }

    func testFormatClampsAndScales() {
        XCTAssertEqual(BackgroundActivityFormat.percent(0.424), "42%")
        XCTAssertEqual(BackgroundActivityFormat.percent(-1), "0%")
        XCTAssertEqual(BackgroundActivityFormat.percent(3), "100%")
        XCTAssertEqual(
            BackgroundActivityFormat.bytes(fraction: 0.5, of: 2_000_000),
            L("activity.bytes", BackgroundActivityFormat.size(1_000_000), BackgroundActivityFormat.size(2_000_000))
        )
        XCTAssertEqual(
            BackgroundActivityFormat.bytes(-5, of: 10),
            L("activity.bytes", BackgroundActivityFormat.size(0), BackgroundActivityFormat.size(10))
        )
        XCTAssertEqual(BackgroundActivityFormat.count(1234), 1234.formatted())
    }

    // MARK: - Feed

    func testFeedReportsObservedDurationOnCompletion() {
        var now = Date(timeIntervalSince1970: 1000)
        let feed = BackgroundActivityFeed(now: { now })
        var completions: [BackgroundActivityCompletion] = []
        let cancellable = feed.completionsPublisher.sink { completions.append($0) }
        defer { cancellable.cancel() }

        feed.publish([makeActivity("x")])
        now = now.addingTimeInterval(90)
        feed.publish([makeActivity("x", detail: "later")])
        feed.complete("x", kind: .download, title: "X", notifies: true)
        feed.publish([])
        feed.complete("unseen", kind: .index, title: "U")

        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(completions[0].activityID, "x")
        XCTAssertEqual(completions[0].duration, 90)
        XCTAssertEqual(completions[0].finishedAt, now)
        XCTAssertTrue(completions[0].notifies)
        XCTAssertNil(completions[1].duration)
        XCTAssertFalse(completions[1].notifies)
    }

    func testFeedRestartsTheClockAfterAFailure() {
        var now = Date(timeIntervalSince1970: 0)
        let feed = BackgroundActivityFeed(now: { now })
        var completions: [BackgroundActivityCompletion] = []
        let cancellable = feed.completionsPublisher.sink { completions.append($0) }
        defer { cancellable.cancel() }

        feed.publish([makeActivity("x")])
        now = now.addingTimeInterval(100)
        feed.publish([makeActivity("x", state: .failed)])
        now = now.addingTimeInterval(5)
        feed.publish([makeActivity("x")])
        now = now.addingTimeInterval(10)
        feed.complete("x", kind: .download, title: "X")

        XCTAssertEqual(completions.first?.duration, 10)
    }

    func testDismissHidesAFailureUntilItChanges() {
        let feed = BackgroundActivityFeed()
        var latest: [BackgroundActivity] = []
        let cancellable = feed.activitiesPublisher.sink { latest = $0 }
        defer { cancellable.cancel() }
        let failure = makeActivity("x", state: .failed)

        feed.publish([failure, makeActivity("y")])
        feed.dismiss("y")
        XCTAssertEqual(latest.map(\.id), ["x", "y"], "only failures can be dismissed")

        feed.dismiss("x")
        XCTAssertEqual(latest.map(\.id), ["y"])
        feed.publish([failure, makeActivity("y", detail: "next")])
        XCTAssertEqual(latest.map(\.id), ["y"], "the same failure stays hidden")

        feed.publish([makeActivity("x", detail: "other", state: .failed), makeActivity("y")])
        XCTAssertEqual(latest.map(\.id), ["x", "y"], "a different failure shows again")
        XCTAssertEqual(feed.reported("x")?.detail, "other")
        XCTAssertEqual(feed.current.map(\.id), ["x", "y"])
    }

    func testDismissedFailureIsForgottenOnceItGoesAway() {
        let feed = BackgroundActivityFeed()
        let failure = makeActivity("x", state: .failed)
        feed.publish([failure])
        feed.dismiss("x")
        feed.publish([])
        feed.publish([failure])
        XCTAssertEqual(feed.current.map(\.id), ["x"])
    }

    // MARK: - Center

    func testCenterMergesSourcesInOrderAndSortsByRank() {
        let center = makeCenter()
        let first = FakeActivitySource(), second = FakeActivitySource()
        center.register(first)
        center.register(second)
        center.register(first)

        first.feed.publish([makeActivity("download", kind: .download), makeActivity("shared")])
        second.feed.publish([
            makeActivity("approval", kind: .agent, state: .attention),
            makeActivity("shared", detail: "dup")
        ])

        XCTAssertEqual(center.activities.map(\.id), ["approval", "download", "shared"])
        XCTAssertEqual(center.activity("shared")?.detail, "", "the first source to report an id owns it")
        XCTAssertEqual(center.activeCount, 3)

        center.perform(.cancel, on: "shared")
        center.perform(.stop, on: "approval")
        center.perform(.pause, on: "missing")
        XCTAssertEqual(first.performed.map(\.1), ["shared"])
        XCTAssertEqual(second.performed.map(\.1), ["approval"])
    }

    func testCenterOpensRoutesWithoutAskingTheSource() {
        let center = makeCenter()
        let source = FakeActivitySource()
        center.register(source)
        var opened: [BackgroundActivity.Route] = []
        center.onOpen = { opened.append($0) }
        var routed = makeActivity("agent", kind: .agent)
        routed.route = .conversation("c1")
        source.feed.publish([routed, makeActivity("plain")])

        center.perform(.open, on: "agent")
        center.perform(.open, on: "plain")

        XCTAssertEqual(opened, [.conversation("c1")])
        XCTAssertTrue(source.performed.isEmpty)
    }

    func testCenterCoalescesUpdates() async throws {
        let center = makeCenter(coalesce: 0.05)
        let source = FakeActivitySource()
        center.register(source)
        var publishes = 0
        let cancellable = center.$activities.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        for index in 0 ..< 10 {
            source.feed.publish([makeActivity("x", detail: "\(index)")])
        }
        XCTAssertTrue(center.activities.isEmpty)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(center.activity("x")?.detail, "9")
        XCTAssertEqual(publishes, 1)
    }

    func testNotificationSettingPersists() throws {
        let (settings, suite) = try makeSettings()
        XCTAssertTrue(settings.backgroundActivityNotificationsEnabled, "notifications default to on")
        let center = BackgroundActivityCenter(settings: settings, notifications: NoopLocalNotificationService(),
                                              coalesceInterval: 0)
        XCTAssertTrue(center.notificationsEnabled)

        center.notificationsEnabled = false

        let reloaded = try SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(reloaded.backgroundActivityNotificationsEnabled)
        XCTAssertFalse(BackgroundActivityCenter(settings: reloaded, notifications: NoopLocalNotificationService())
            .notificationsEnabled)
    }

    func testRecentKeepsNewestFirstAndIsCapped() {
        let center = makeCenter()
        let source = FakeActivitySource()
        center.register(source)

        for index in 0 ..< BackgroundActivityCenter.recentLimit + 3 {
            source.feed.complete("x\(index)", kind: .index, title: "T\(index)")
        }

        XCTAssertEqual(center.recent.count, BackgroundActivityCenter.recentLimit)
        XCTAssertEqual(center.recent.first?.title, "T\(BackgroundActivityCenter.recentLimit + 2)")
        center.clearRecent()
        XCTAssertTrue(center.recent.isEmpty)
    }

    func testOnlyLongNotifyingCompletionsSendNotifications() async throws {
        let notifications = RecordingNotifications()
        var now = Date(timeIntervalSince1970: 0)
        let center = makeCenter(notifications: notifications)
        let source = FakeActivitySource(feed: BackgroundActivityFeed(now: { now }))
        center.register(source)

        source.feed.publish([makeActivity("long"), makeActivity("short"), makeActivity("quiet")])
        now = now.addingTimeInterval(BackgroundActivityCenter.notificationThreshold)
        source.feed.complete("long", kind: .download, title: "Long", notifies: true)
        source.feed.complete("quiet", kind: .download, title: "Quiet", notifies: false)
        source.feed.publish([makeActivity("short")])
        now = now.addingTimeInterval(1)
        source.feed.publish([])
        source.feed.publish([makeActivity("short")])
        source.feed.complete("short", kind: .download, title: "Short", notifies: true)
        center.notificationsEnabled = false
        source.feed.publish([makeActivity("off")])
        now = now.addingTimeInterval(500)
        source.feed.complete("off", kind: .download, title: "Off", notifies: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(notifications.sent.map(\.body), [L("activity.notification.body", "Long")])
        XCTAssertEqual(notifications.sent.first?.title, L("activity.notification.title"))
        XCTAssertEqual(notifications.sent.first?.identifier, "ai.gulu.app.typeflux.activity.long")
        XCTAssertEqual(center.recent.count, 4)
    }

    // MARK: - Helpers

    private func makeCenter(notifications: LocalNotificationSending = NoopLocalNotificationService(),
                            coalesce: TimeInterval = 0) -> BackgroundActivityCenter {
        let (settings, _) = try! makeSettings()
        return BackgroundActivityCenter(settings: settings, notifications: notifications, coalesceInterval: coalesce)
    }

    private func makeSettings() throws -> (SettingsStore, String) {
        let suite = "BackgroundActivityCenterTests.\(UUID().uuidString)"
        suiteNames.append(suite)
        return try (SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite))), suite)
    }
}

func makeActivity(_ id: String, kind: BackgroundActivity.Kind = .download, detail: String = "",
                  state: BackgroundActivity.State = .running) -> BackgroundActivity {
    BackgroundActivity(id: id, kind: kind, title: id.capitalized, detail: detail, progress: nil, state: state)
}

@MainActor
final class FakeActivitySource: BackgroundActivitySource {
    let feed: BackgroundActivityFeed
    var performed: [(BackgroundActivity.Action, String)] = []

    init(feed: BackgroundActivityFeed? = nil) {
        self.feed = feed ?? BackgroundActivityFeed()
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> {
        feed.activitiesPublisher
    }

    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> {
        feed.completionsPublisher
    }

    func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        performed.append((action, activityID))
    }
}

final class RecordingNotifications: LocalNotificationSending, @unchecked Sendable {
    struct Sent { let title: String; let body: String; let identifier: String }
    private let lock = NSLock()
    private var storage: [Sent] = []
    var sent: [Sent] {
        lock.withLock { storage }
    }

    func sendLocalNotification(title: String, body: String, identifier: String) async {
        lock.withLock { storage.append(Sent(title: title, body: body, identifier: identifier)) }
    }
}
