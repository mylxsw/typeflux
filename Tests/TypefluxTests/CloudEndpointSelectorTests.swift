@testable import Typeflux
import XCTest

final class CloudEndpointSelectorTests: XCTestCase {
    private let urlA = URL(string: "https://a.example")!
    private let urlB = URL(string: "https://b.example")!
    private let urlC = URL(string: "https://c.example")!

    // MARK: - Ordering

    func testOrderedEndpointsPreservesConfiguredOrderBeforeProbes() async {
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber()
        )
        let ordered = await selector.orderedEndpoints()
        XCTAssertEqual(ordered, [urlA, urlB, urlC])
    }

    func testOrderedEndpointsDeduplicatesDuplicateBaseURLs() async {
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlA],
            prober: StubProber()
        )
        let ordered = await selector.orderedEndpoints()
        XCTAssertEqual(ordered, [urlA, urlB])
    }

    func testOrderedEndpointsSortsByAscendingLatency() async {
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber()
        )
        await selector.reportSuccess(urlA, latencyMs: 300)
        await selector.reportSuccess(urlB, latencyMs: 50)
        await selector.reportSuccess(urlC, latencyMs: 150)

        let ordered = await selector.orderedEndpoints()
        XCTAssertEqual(ordered, [urlB, urlC, urlA])
    }

    func testPreferredEndpointTakesPriorityOverFasterEndpoint() async {
        let preferred = urlC
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber(),
            preferredEndpoint: { preferred }
        )
        await selector.reportSuccess(urlA, latencyMs: 40)
        await selector.reportSuccess(urlB, latencyMs: 80)
        await selector.reportSuccess(urlC, latencyMs: 200)

        let ordered = await selector.orderedEndpoints()

        XCTAssertEqual(ordered, [urlC, urlA, urlB])
    }

    func testPreferredEndpointFallsBackWhileInCooldown() async {
        let preferred = urlC
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 60
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber(),
            config: config,
            preferredEndpoint: { preferred }
        )
        await selector.reportSuccess(urlA, latencyMs: 40)
        await selector.reportSuccess(urlB, latencyMs: 80)
        await selector.reportFailure(urlC, error: SampleError.boom)

        let ordered = await selector.orderedEndpoints()

        XCTAssertEqual(ordered, [urlA, urlB, urlC])
    }

    func testOrderedEndpointsPlacesUnknownLatencyAfterKnown() async {
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber()
        )
        await selector.reportSuccess(urlB, latencyMs: 200)

        let ordered = await selector.orderedEndpoints()
        // urlB (latency known) first, then urlA and urlC in their insertion order.
        XCTAssertEqual(ordered, [urlB, urlA, urlC])
    }

    func testOrderedEndpointsMovesCooldownEndpointsToTheBack() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 60
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber(),
            config: config
        )
        await selector.reportSuccess(urlA, latencyMs: 200)
        await selector.reportSuccess(urlB, latencyMs: 100)
        await selector.reportFailure(urlA, error: SampleError.boom)

        let ordered = await selector.orderedEndpoints()
        // Healthy endpoints first (urlB by latency, urlC unknown), cooldown last (urlA).
        XCTAssertEqual(ordered, [urlB, urlC, urlA])
    }

    func testPrimaryFirstEndpointsPreservesConfiguredOrderDespiteLatency() async {
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber()
        )
        await selector.reportSuccess(urlA, latencyMs: 300)
        await selector.reportSuccess(urlB, latencyMs: 50)
        await selector.reportSuccess(urlC, latencyMs: 150)

        let ordered = await selector.primaryFirstEndpoints()
        XCTAssertEqual(ordered, [urlA, urlB, urlC])
    }

    func testPrimaryFirstEndpointsHonorsPreferredEndpoint() async {
        let preferred = urlC
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber(),
            preferredEndpoint: { preferred }
        )

        let ordered = await selector.primaryFirstEndpoints()

        XCTAssertEqual(ordered, [urlC, urlA, urlB])
    }

    func testPrimaryFirstEndpointsMovesCooldownPrimaryBehindHealthyBackups() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 60
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB, urlC],
            prober: StubProber(),
            config: config
        )
        await selector.reportFailure(urlA, error: SampleError.boom)

        let ordered = await selector.primaryFirstEndpoints()
        XCTAssertEqual(ordered, [urlB, urlC, urlA])
    }

    func testOrderedEndpointsSortsCooldownByExpiryAscending() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 60
        config.maxCooldown = 60 * 60

        let timeline = ClockStub(start: Date(timeIntervalSince1970: 1_700_000_000))
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB],
            prober: StubProber(),
            config: config,
            now: timeline.now
        )

        // First failure on urlA at t=0 → cooldown ends ~60s later.
        await selector.reportFailure(urlA, error: SampleError.boom)
        timeline.advance(by: 10)
        // First failure on urlB at t=10 → cooldown ends ~70s later.
        await selector.reportFailure(urlB, error: SampleError.boom)

        let ordered = await selector.orderedEndpoints()
        XCTAssertEqual(ordered, [urlA, urlB])
    }

    // MARK: - EWMA

    func testReportSuccessBlendsLatencyWithEWMA() async {
        var config = CloudEndpointSelectorConfig.default
        config.ewmaAlpha = 0.5
        let selector = CloudEndpointSelector(
            baseURLs: [urlA],
            prober: StubProber(),
            config: config
        )
        await selector.reportSuccess(urlA, latencyMs: 100)
        await selector.reportSuccess(urlA, latencyMs: 200)
        let snapshots = await selector.snapshot()
        // EWMA: 0.5 * 200 + 0.5 * 100 = 150.
        XCTAssertEqual(snapshots.first?.latencyMs ?? .nan, 150, accuracy: 0.0001)
    }

    func testReportSuccessClearsFailureBookkeeping() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        let selector = CloudEndpointSelector(
            baseURLs: [urlA],
            prober: StubProber(),
            config: config
        )
        await selector.reportFailure(urlA, error: SampleError.boom)
        await selector.reportSuccess(urlA, latencyMs: 80, serverID: "srv", serverVersion: "1.2.3")

        let snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.consecutiveFailures, 0)
        XCTAssertNil(snapshot?.cooldownUntil)
        XCTAssertNil(snapshot?.lastError)
        XCTAssertEqual(snapshot?.serverID, "srv")
        XCTAssertEqual(snapshot?.serverVersion, "1.2.3")
    }

    // MARK: - Cooldown

    func testReportFailureEntersCooldownAfterThresholdReached() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 3
        config.baseCooldown = 30
        let timeline = ClockStub(start: Date(timeIntervalSince1970: 1_700_000_000))
        let selector = CloudEndpointSelector(
            baseURLs: [urlA],
            prober: StubProber(),
            config: config,
            now: timeline.now
        )

        await selector.reportFailure(urlA, error: SampleError.boom)
        await selector.reportFailure(urlA, error: SampleError.boom)
        // Under threshold: no cooldown yet.
        var snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.consecutiveFailures, 2)
        XCTAssertNil(snapshot?.cooldownUntil)

        await selector.reportFailure(urlA, error: SampleError.boom)
        snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.consecutiveFailures, 3)
        XCTAssertEqual(snapshot?.cooldownUntil, timeline.current.addingTimeInterval(30))
    }

    func testCooldownAppliesExponentialBackoffBoundedByMax() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 30
        config.maxCooldown = 300
        let timeline = ClockStub(start: Date(timeIntervalSince1970: 1_700_000_000))
        let selector = CloudEndpointSelector(
            baseURLs: [urlA],
            prober: StubProber(),
            config: config,
            now: timeline.now
        )

        // 1st failure at threshold → 30s cooldown.
        await selector.reportFailure(urlA, error: SampleError.boom)
        var snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.cooldownUntil, timeline.current.addingTimeInterval(30))

        // 2nd failure → 60s cooldown.
        await selector.reportFailure(urlA, error: SampleError.boom)
        snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.cooldownUntil, timeline.current.addingTimeInterval(60))

        // 5th failure → 30 * 2^4 = 480s, capped at 300.
        await selector.reportFailure(urlA, error: SampleError.boom)
        await selector.reportFailure(urlA, error: SampleError.boom)
        await selector.reportFailure(urlA, error: SampleError.boom)
        snapshot = await selector.snapshot().first
        XCTAssertEqual(snapshot?.cooldownUntil, timeline.current.addingTimeInterval(300))
    }

    // MARK: - probeAll

    func testProbeAllRecordsSuccessAndFailureFromProber() async {
        let prober = StubProber()
        await prober.setResponse(
            for: urlA,
            response: .success(CloudEndpointProbeResult(
                latencyMs: 42,
                serverID: "s1",
                serverVersion: "1.0",
                nonceMatches: true
            ))
        )
        await prober.setResponse(
            for: urlB,
            response: .failure(CloudEndpointProbeError.timedOut)
        )
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB],
            prober: prober
        )
        await selector.probeAll()

        let snapshot = await selector.snapshot()
        XCTAssertEqual(snapshot[0].latencyMs, 42)
        XCTAssertEqual(snapshot[0].serverID, "s1")
        XCTAssertEqual(snapshot[0].serverVersion, "1.0")
        XCTAssertEqual(snapshot[0].consecutiveFailures, 0)

        XCTAssertEqual(snapshot[1].consecutiveFailures, 1)
        XCTAssertNil(snapshot[1].latencyMs)
        XCTAssertNotNil(snapshot[1].lastError)
    }

    // MARK: - primaryEndpoint fallback

    func testPrimaryEndpointFallsBackToFirstConfiguredWhenAllInCooldown() async {
        var config = CloudEndpointSelectorConfig.default
        config.failureThreshold = 1
        config.baseCooldown = 300
        let timeline = ClockStub(start: Date(timeIntervalSince1970: 1_700_000_000))
        let selector = CloudEndpointSelector(
            baseURLs: [urlA, urlB],
            prober: StubProber(),
            config: config,
            now: timeline.now
        )
        await selector.reportFailure(urlA, error: SampleError.boom)
        await selector.reportFailure(urlB, error: SampleError.boom)

        // Both in cooldown; orderedEndpoints still returns them (cooldown sorted),
        // so primaryEndpoint returns the one with the nearest expiry.
        let primary = await selector.primaryEndpoint()
        XCTAssertTrue([urlA, urlB].contains(primary))
    }
}

// MARK: - Helpers

private enum SampleError: Error {
    case boom
}

private actor StubProber: CloudEndpointProbing {
    private var responses: [URL: Result<CloudEndpointProbeResult, CloudEndpointProbeError>] = [:]

    func setResponse(for url: URL, response: Result<CloudEndpointProbeResult, CloudEndpointProbeError>) {
        responses[url] = response
    }

    func probe(baseURL: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        switch responses[baseURL] {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        case .none:
            throw CloudEndpointProbeError.timedOut
        }
    }
}

private final class ClockStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: Date

    init(start: Date) {
        _current = start
    }

    var current: Date {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _current = _current.addingTimeInterval(seconds)
    }

    var now: @Sendable () -> Date {
        { [weak self] in
            self?.current ?? Date()
        }
    }
}
