import XCTest
@testable import Typeflux

final class UsageCounterReporterTests: XCTestCase {
    private func make(_ defaults: UserDefaults, _ transport: CounterTransport) -> UsageCounterReporter {
        UsageCounterReporter(defaults: defaults, transport: transport,
            clientInfoProvider: TypefluxCloudClientInfoProvider { TypefluxCloudClientInfo(
                appName: "Typeflux", appVersion: "1", clientID: "test", localeIdentifier: "en",
                preferredLanguages: ["en"], osName: "macOS", osVersion: "15", architecture: "arm64") },
            interval: .seconds(3600), now: { Date(timeIntervalSince1970: 1_794_355_200) })
    }

    func testTenThousandOperationsProduceOneCompactSnapshotAndRestartReplaysSameTotal() async throws {
        let suite = "UsageCounterTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = CounterTransport()
        let reporter = make(defaults, transport)
        for _ in 0..<10_000 { reporter.increment(266) }
        XCTAssertTrue(transport.events.isEmpty)
        await reporter.flush()
        XCTAssertEqual(transport.events.count, 1)
        XCTAssertEqual(transport.events[0].properties["counts"], "[[266,10000]]")
        let epoch = transport.events[0].properties["epoch"]
        await reporter.flush()
        XCTAssertEqual(transport.events.count, 1)
        let restarted = make(defaults, transport)
        await restarted.flush()
        XCTAssertEqual(transport.events.last?.properties["epoch"], epoch)
        XCTAssertEqual(transport.events.last?.properties["counts"], "[[266,10000]]")
        reporter.setEnabled(false); restarted.setEnabled(false)
    }

    func testRetryAndIncrementDuringSendKeepTheLatestTotal() async throws {
        let suite = "UsageCounterTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = CounterTransport()
        let reporter = make(defaults, transport)
        transport.fail = true
        reporter.increment(266)
        await reporter.flush()
        XCTAssertTrue(transport.events.isEmpty)
        transport.fail = false
        transport.onSend = { reporter.increment(266) }
        await reporter.flush()
        transport.onSend = nil
        await reporter.flush()
        XCTAssertEqual(transport.events.map { $0.properties["counts"] }, ["[[266,1]]", "[[266,2]]"])
        reporter.setEnabled(false)
    }

    func testConsentErasesPendingAndRotatesEpochAndInvalidMetricsAreIgnored() async throws {
        let suite = "UsageCounterTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = CounterTransport(), reporter = make(defaults, CounterTransport())
        reporter.increment(266)
        reporter.setEnabled(false)
        reporter.increment(266)
        let restarted = make(defaults, transport)
        await restarted.flush()
        XCTAssertTrue(transport.events.isEmpty)
        restarted.increment(-1); restarted.increment(266, amount: -1)
        await restarted.flush()
        XCTAssertTrue(transport.events.isEmpty)
        restarted.setEnabled(false)
    }

    func testSnapshotBoundsAndMappingAcrossFeatures() async throws {
        let suite = "UsageCounterTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = CounterTransport(), reporter = make(defaults, CounterTransport())
        let batching = make(defaults, transport)
        for id in UsageMetricCatalog.validIDs { batching.increment(id, amount: 1_000_000_000) }
        await batching.flush()
        XCTAssertEqual(transport.events.count, (UsageMetricCatalog.validIDs.count + 127) / 128)
        for event in transport.events {
            let raw = try XCTUnwrap(event.properties["counts"])
            XCTAssertLessThanOrEqual(raw.utf8.count, 3072)
            let pairs = try JSONDecoder().decode([[Int]].self, from: Data(raw.utf8))
            XCTAssertLessThanOrEqual(pairs.count, 128)
        }
        for (feature, action, prop, value, key) in [
            ("launcher", "action_executed", "action", "copy", "launcher.action.copy"),
            ("translation", "action_executed", "action", "speak", "translation.action.speak"),
            ("clipboard", "action_executed", "action", "pastePlainText", "clipboard.action.pastePlainText"),
            ("ring", "action_triggered", "action", "feature", "ring.action.feature"),
            ("keyword", "executed", "plugin_id", "translate", "keyword.plugin.translate"),
            ("workflow", "started", "runtime", "shell", "workflow.runtime.shell"),
            ("screenshot", "started", "capture_mode", "region", "screenshot.capture.region")
        ] {
            XCTAssertTrue(UsageMetricCatalog.metrics(eventName: feature + "_" + action,
                properties: ["feature": feature, prop: value]).contains(try XCTUnwrap(UsageMetricCatalog.ids[key])))
        }
        XCTAssertTrue(UsageMetricCatalog.metrics(eventName: "launcher_action_executed", properties: ["feature": "launcher", "action": "private document title"]).allSatisfy { $0 == UsageMetricCatalog.ids["launcher.event.action_executed"] })
        reporter.setEnabled(false); batching.setEnabled(false)
    }
}

private final class CounterTransport: AppAnalyticsTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppAnalyticsEvent] = []
    var fail = false
    var onSend: (@Sendable () -> Void)?
    var events: [AppAnalyticsEvent] { lock.withLock { stored } }
    func send(events: [AppAnalyticsEvent]) async throws {
        if fail { throw URLError(.notConnectedToInternet) }
        onSend?()
        lock.withLock { stored.append(contentsOf: events) }
    }
}
