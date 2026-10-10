@testable import Typeflux
import XCTest

/// A cached ASR route carries a one-use grant: whichever way a recording
/// obtains it, the same grant must never be handed out a second time.
final class TypefluxOfficialASRRouteCacheGrantTests: XCTestCase {
    func testRecordingThatTakesOverAPrefetchKeepsItsGrantOutOfTheCache() async throws {
        let upstream = RecordingRoutingClient(servers: [URL(string: "https://asr.example.com")!], parkFetch: 1)
        let cache = makeCache(upstream: upstream)
        let prefetch = own(releasing: [upstream.gate]) {
            await cache.prefetch(accessToken: "account-token")
            return ""
        }
        try await upstream.gate.waitUntilParked(unlessFinished: prefetch)

        // The recording starts while the prefetch is still in flight. It may
        // take over that request or, if the prefetch finished first, its
        // cached result; either way it gets the first grant.
        let recording = own(releasing: [upstream.gate]) {
            try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput).grantToken
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        await upstream.gate.release()
        let first = try await recording.value
        _ = try await prefetch.value

        let second = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput).grantToken
        XCTAssertEqual(first, "grant-1")
        XCTAssertNotEqual(second, first)
    }

    func testFailedRouteRequestIsNotLeftInFlightForTheNextRecording() async throws {
        let upstream = FailingFirstRoutingClient()
        let cache = makeCache(upstream: upstream)

        do {
            _ = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)
            XCTFail("Expected the route request to fail")
        } catch {
            XCTAssertEqual(error as? URLError, URLError(.timedOut))
        }
        let route = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)

        XCTAssertEqual(route.grantToken, "grant-2")
    }

    func testPrefetchFailureLeavesNoRouteBehind() async throws {
        let upstream = FailingFirstRoutingClient()
        let cache = makeCache(upstream: upstream)

        await cache.prefetch(accessToken: "account-token")
        let route = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)

        XCTAssertEqual(route.grantToken, "grant-2")
        let calls = await upstream.calls
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func testFreshPrefetchedRouteIsNotRequestedAgain() async throws {
        let upstream = RecordingRoutingClient(servers: [URL(string: "https://asr.example.com")!])
        let cache = makeCache(upstream: upstream)

        await cache.prefetch(accessToken: "account-token")
        await cache.prefetch(accessToken: "account-token")

        let tokens = await upstream.accessTokens
        XCTAssertEqual(tokens, ["account-token"])
    }

    // MARK: - Helpers

    /// A cache whose scheduled refreshes never fire during a test. It is
    /// invalidated on every exit, which cancels its background requests.
    private func makeCache(upstream: any TypefluxOfficialASRRoutingClient) -> TypefluxOfficialASRRouteCache {
        let cache = TypefluxOfficialASRRouteCache(
            upstream: upstream,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        addTeardownBlock { await cache.invalidate() }
        return cache
    }

    /// A worker the test owns: on every exit it is cancelled, its gates are
    /// opened and it is joined.
    private func own(
        releasing gates: [ParkingGate],
        _ operation: @escaping @Sendable () async throws -> String
    ) -> OwnedWorker<String> {
        let worker = OwnedWorker(operation)
        addTeardownBlock { await worker.stop(releasing: gates) }
        return worker
    }
}

/// Fails the first route request, then issues `grant-<n>` per request.
private actor FailingFirstRoutingClient: TypefluxOfficialASRRoutingClient {
    private(set) var calls = 0

    func fetchRoute(
        accessToken _: String,
        scenario _: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        calls += 1
        if calls == 1 { throw URLError(.timedOut) }
        return .webSocket(
            token: "grant-\(calls)",
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: [URL(string: "https://asr.example.com")!]
        )
    }
}

private extension TypefluxOfficialASRRouteDecision {
    var grantToken: String {
        switch self {
        case let .webSocket(token, _, _, _, _): token
        }
    }
}
