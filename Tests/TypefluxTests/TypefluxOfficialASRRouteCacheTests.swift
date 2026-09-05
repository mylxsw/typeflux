@testable import Typeflux
import XCTest

final class TypefluxOfficialASRRouteCacheTests: XCTestCase {
    func testPrefetchedRouteIsConsumedOnceAndRefilledInBackground() async throws {
        let upstream = RouteSequenceClient()
        let cache = TypefluxOfficialASRRouteCache(
            upstream: upstream,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        await cache.prefetch(accessToken: "account-token")
        let first = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)
        let second = try await cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)

        XCTAssertEqual(first.token, "route-1")
        XCTAssertEqual(second.token, "route-2")
        let requestCount = await upstream.requestCount()
        XCTAssertGreaterThanOrEqual(requestCount, 2)
        await cache.invalidate()
    }

    func testUnusedRouteSchedulesRefreshThirtySecondsBeforeExpiry() async {
        let upstream = RouteSequenceClient(expiresInSeconds: 3_600)
        let sleepRecorder = RouteCacheSleepRecorder()
        let cache = TypefluxOfficialASRRouteCache(
            upstream: upstream,
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { delay in try await sleepRecorder.sleep(delay) }
        )

        await cache.prefetch(accessToken: "account-token")
        for _ in 0 ..< 20 {
            if !(await sleepRecorder.delays()).isEmpty { break }
            await Task.yield()
        }

        let delays = await sleepRecorder.delays()
        XCTAssertEqual(delays.first, 3_570)
        await cache.invalidate()
    }

    func testConcurrentConsumersReceiveDistinctRoutes() async throws {
        let upstream = RouteSequenceClient(delay: 0.05)
        let cache = TypefluxOfficialASRRouteCache(
            upstream: upstream,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        async let first = cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)
        async let second = cache.fetchRoute(accessToken: "account-token", scenario: .voiceInput)
        let tokens = try await [first.token, second.token]

        XCTAssertEqual(Set(tokens).count, 2)
        await cache.invalidate()
    }

    func testAccessTokenChangeDoesNotConsumePreviousAccountsRoute() async throws {
        let upstream = RouteSequenceClient()
        let cache = TypefluxOfficialASRRouteCache(
            upstream: upstream,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        await cache.prefetch(accessToken: "first-account")
        let route = try await cache.fetchRoute(accessToken: "second-account", scenario: .voiceInput)

        XCTAssertEqual(route.token, "route-2")
        await cache.invalidate()
    }
}

private actor RouteSequenceClient: TypefluxOfficialASRRoutingClient {
    private var count = 0
    private let expiresInSeconds: Int
    private let delay: TimeInterval

    init(expiresInSeconds: Int = 3_600, delay: TimeInterval = 0) {
        self.expiresInSeconds = expiresInSeconds
        self.delay = delay
    }

    func fetchRoute(
        accessToken _: String,
        scenario _: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        count += 1
        let token = "route-\(count)"
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        return .webSocket(
            token: token,
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: expiresInSeconds,
            serverBaseURLs: [URL(string: "https://asr.example.com")!]
        )
    }

    func requestCount() -> Int {
        count
    }
}

private actor RouteCacheSleepRecorder {
    private var recordedDelays: [TimeInterval] = []

    func sleep(_ delay: TimeInterval) async throws {
        recordedDelays.append(delay)
        try await Task.sleep(for: .seconds(60))
    }

    func delays() -> [TimeInterval] {
        recordedDelays
    }
}

private extension TypefluxOfficialASRRouteDecision {
    var token: String {
        switch self {
        case let .webSocket(token, _, _, _, _): token
        }
    }
}
