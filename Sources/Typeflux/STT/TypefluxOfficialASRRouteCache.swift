import Foundation

/// Keeps one unused ASR route ready per scenario.
///
/// Routes are consumed once because the token callback contains a per-session
/// usage report identifier. Reusing a token would merge multiple recordings
/// into one billing record. After checkout, the next route is fetched in the
/// background; an unused route is rotated 30 seconds before expiration.
actor TypefluxOfficialASRRouteCache: TypefluxOfficialASRRoutingClient {
    static let shared = TypefluxOfficialASRRouteCache()

    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private struct Entry {
        let accessToken: String
        let route: TypefluxOfficialASRRouteDecision
        let expiresAt: Date
    }

    private struct InFlightFetch {
        let id: UUID
        let accessToken: String
        let task: Task<TypefluxOfficialASRRouteDecision, Error>
        var reservedForConsumer: Bool
    }

    private static let refreshLeadTime: TimeInterval = 30
    private static let fallbackLifetime: TimeInterval = 60 * 60
    private static let refreshRetryDelay: TimeInterval = 5

    private let upstream: any TypefluxOfficialASRRoutingClient
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private var entries: [TypefluxCloudScenario: Entry] = [:]
    private var fetches: [TypefluxCloudScenario: InFlightFetch] = [:]
    private var refreshTasks: [TypefluxCloudScenario: Task<Void, Never>] = [:]

    init(
        upstream: any TypefluxOfficialASRRoutingClient = TypefluxOfficialASRRoutingHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.upstream = upstream
        self.now = now
        self.sleep = sleep
    }

    func fetchRoute(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        let current = now()
        if let entry = entries[scenario],
           entry.accessToken == accessToken,
           entry.expiresAt > current.addingTimeInterval(Self.refreshLeadTime) {
            entries[scenario] = nil
            refreshTasks.removeValue(forKey: scenario)?.cancel()
            refillInBackground(accessToken: accessToken, scenario: scenario)
            return entry.route
        }

        entries[scenario] = nil
        refreshTasks.removeValue(forKey: scenario)?.cancel()
        let route = try await fetchForConsumer(accessToken: accessToken, scenario: scenario)
        refillInBackground(accessToken: accessToken, scenario: scenario)
        return route
    }

    func prefetch(accessToken: String, scenario: TypefluxCloudScenario = .voiceInput) async {
        if let entry = entries[scenario],
           entry.accessToken == accessToken,
           entry.expiresAt > now().addingTimeInterval(Self.refreshLeadTime) {
            return
        }
        do {
            try await fillCache(accessToken: accessToken, scenario: scenario)
        } catch is CancellationError {
            return
        } catch {
            NetworkDebugLogger.logError(context: "ASR route prefetch failed", error: error)
        }
    }

    func invalidate() {
        entries.removeAll()
        fetches.values.forEach { $0.task.cancel() }
        fetches.removeAll()
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
    }

    private func fetchForConsumer(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        let fetch: InFlightFetch
        if var current = fetches[scenario],
           current.accessToken == accessToken,
           !current.reservedForConsumer {
            current.reservedForConsumer = true
            fetches[scenario] = current
            fetch = current
        } else {
            if let current = fetches[scenario], current.accessToken != accessToken {
                current.task.cancel()
                fetches[scenario] = nil
            } else if fetches[scenario]?.reservedForConsumer == true {
                // A route carries one usage report identifier, so concurrent
                // consumers must never share the same in-flight token.
                return try await upstream.fetchRoute(accessToken: accessToken, scenario: scenario)
            }
            fetch = makeFetch(accessToken: accessToken, scenario: scenario, reservedForConsumer: true)
            fetches[scenario] = fetch
        }
        do {
            let route = try await fetch.task.value
            completeFetch(id: fetch.id, scenario: scenario)
            return route
        } catch {
            completeFetch(id: fetch.id, scenario: scenario)
            throw error
        }
    }

    private func fillCache(accessToken: String, scenario: TypefluxCloudScenario) async throws {
        let fetch: InFlightFetch
        if let current = fetches[scenario], current.accessToken == accessToken {
            fetch = current
        } else {
            fetches.removeValue(forKey: scenario)?.task.cancel()
            fetch = makeFetch(accessToken: accessToken, scenario: scenario, reservedForConsumer: false)
            fetches[scenario] = fetch
        }
        do {
            let route = try await fetch.task.value
            guard let current = fetches[scenario], current.id == fetch.id else { return }
            fetches[scenario] = nil
            if !current.reservedForConsumer {
                store(route, accessToken: accessToken, scenario: scenario)
            }
        } catch {
            completeFetch(id: fetch.id, scenario: scenario)
            throw error
        }
    }

    private func makeFetch(
        accessToken: String,
        scenario: TypefluxCloudScenario,
        reservedForConsumer: Bool
    ) -> InFlightFetch {
        let upstream = upstream
        return InFlightFetch(
            id: UUID(),
            accessToken: accessToken,
            task: Task { try await upstream.fetchRoute(accessToken: accessToken, scenario: scenario) },
            reservedForConsumer: reservedForConsumer
        )
    }

    private func completeFetch(id: UUID, scenario: TypefluxCloudScenario) {
        guard fetches[scenario]?.id == id else { return }
        fetches[scenario] = nil
    }

    private func refillInBackground(accessToken: String, scenario: TypefluxCloudScenario) {
        Task { [weak self] in
            await self?.prefetch(accessToken: accessToken, scenario: scenario)
        }
    }

    private func store(
        _ route: TypefluxOfficialASRRouteDecision,
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) {
        let current = now()
        let expiration = route.expirationDate(relativeTo: current)
        entries[scenario] = Entry(accessToken: accessToken, route: route, expiresAt: expiration)
        scheduleRefresh(accessToken: accessToken, scenario: scenario, expiresAt: expiration)
    }

    private func scheduleRefresh(
        accessToken: String,
        scenario: TypefluxCloudScenario,
        expiresAt: Date
    ) {
        refreshTasks.removeValue(forKey: scenario)?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(now()) - Self.refreshLeadTime)
        let sleep = sleep
        refreshTasks[scenario] = Task { [weak self] in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                await self?.refresh(accessToken: accessToken, scenario: scenario)
            } catch {
                // Cancellation means the cached route was consumed or invalidated.
            }
        }
    }

    private func refresh(accessToken: String, scenario: TypefluxCloudScenario) async {
        guard entries[scenario]?.accessToken == accessToken else { return }
        do {
            try await fillCache(accessToken: accessToken, scenario: scenario)
        } catch is CancellationError {
            return
        } catch {
            NetworkDebugLogger.logError(context: "Scheduled ASR route refresh failed", error: error)
            guard entries[scenario]?.expiresAt ?? .distantPast > now() else {
                entries[scenario] = nil
                return
            }
            scheduleRefresh(
                accessToken: accessToken,
                scenario: scenario,
                expiresAt: now().addingTimeInterval(Self.refreshLeadTime + Self.refreshRetryDelay)
            )
        }
    }
}

private extension TypefluxOfficialASRRouteDecision {
    func expirationDate(relativeTo now: Date) -> Date {
        switch self {
        case let .webSocket(_, _, expiresAt, expiresInSeconds, _):
            if let expiresAt {
                return Date(timeIntervalSince1970: TimeInterval(expiresAt))
            }
            return now.addingTimeInterval(TimeInterval(expiresInSeconds ?? 3_600))
        }
    }
}
