import Foundation
import os

/// Diagnostic snapshot describing the current health of one cloud endpoint.
struct CloudEndpointStatus: Sendable, Equatable {
    let baseURL: URL
    /// Smoothed round-trip latency in milliseconds. `nil` until the first
    /// successful probe or live request.
    let latencyMs: Double?
    let lastProbeAt: Date?
    let lastSuccessAt: Date?
    let consecutiveFailures: Int
    let cooldownUntil: Date?
    let serverID: String?
    let serverVersion: String?
    let lastError: String?

    var inCooldown: Bool {
        guard let cooldownUntil else { return false }
        return cooldownUntil > Date()
    }
}

/// Tunables for `CloudEndpointSelector`. Exposed as a struct so tests can
/// override individual values while keeping production defaults centralized.
struct CloudEndpointSelectorConfig: Sendable {
    var probeInterval: TimeInterval = 15 * 60
    var probeTimeout: TimeInterval = 3
    /// Smoothing factor for the latency EWMA. 0.3 means each new sample
    /// contributes 30%; established readings stay relatively stable across
    /// transient blips.
    var ewmaAlpha: Double = 0.3
    /// Number of consecutive failures before an endpoint enters cooldown.
    var failureThreshold: Int = 3
    /// Initial cooldown duration. Subsequent failures double it (capped by
    /// `maxCooldown`).
    var baseCooldown: TimeInterval = 30
    var maxCooldown: TimeInterval = 5 * 60

    static let `default` = CloudEndpointSelectorConfig()
}

/// Actor that tracks per-endpoint latency and health for the configured
/// Typeflux Cloud servers, and chooses the order callers should try them in.
///
/// The selector is intentionally storage-only: a separate scheduler is
/// responsible for invoking `probeAll()` periodically. This split keeps the
/// actor easy to drive from tests without dealing with timers.
actor CloudEndpointSelector {
    private struct EndpointState {
        var latencyMs: Double?
        var lastProbeAt: Date?
        var lastSuccessAt: Date?
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date?
        var serverID: String?
        var serverVersion: String?
        var lastError: String?
    }

    private let config: CloudEndpointSelectorConfig
    private let prober: CloudEndpointProbing
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudEndpointSelector")

    private let orderedURLs: [URL]
    private var states: [URL: EndpointState]

    init(
        baseURLs: [URL],
        prober: CloudEndpointProbing,
        config: CloudEndpointSelectorConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(!baseURLs.isEmpty, "CloudEndpointSelector requires at least one base URL")
        // Preserve the configured order while removing duplicates.
        var seen = Set<URL>()
        var unique: [URL] = []
        for url in baseURLs where seen.insert(url).inserted {
            unique.append(url)
        }
        self.orderedURLs = unique
        self.config = config
        self.prober = prober
        self.now = now
        self.states = Dictionary(uniqueKeysWithValues: unique.map { ($0, EndpointState()) })
    }

    /// Returns endpoints in the order callers should try them:
    /// 1. Healthy endpoints, sorted by EWMA latency ascending (unknown latency last,
    ///    falling back to the configured insertion order to break ties).
    /// 2. Endpoints currently in cooldown, sorted by cooldown expiry ascending.
    func orderedEndpoints() -> [URL] {
        let snapshot = self.now()

        struct Ranked {
            let url: URL
            let inCooldown: Bool
            let latency: Double?
            let cooldownUntil: Date?
            let insertionIndex: Int
        }

        let ranked: [Ranked] = orderedURLs.enumerated().map { idx, url in
            let state = states[url] ?? EndpointState()
            let inCooldown = (state.cooldownUntil ?? .distantPast) > snapshot
            return Ranked(
                url: url,
                inCooldown: inCooldown,
                latency: state.latencyMs,
                cooldownUntil: state.cooldownUntil,
                insertionIndex: idx
            )
        }

        return ranked.sorted { lhs, rhs in
            // Healthy first.
            if lhs.inCooldown != rhs.inCooldown {
                return !lhs.inCooldown
            }
            if lhs.inCooldown && rhs.inCooldown {
                let lhsExpiry = lhs.cooldownUntil ?? .distantFuture
                let rhsExpiry = rhs.cooldownUntil ?? .distantFuture
                if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
                return lhs.insertionIndex < rhs.insertionIndex
            }
            // Both healthy: known latency before unknown, then ascending.
            switch (lhs.latency, rhs.latency) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.insertionIndex < rhs.insertionIndex
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.insertionIndex < rhs.insertionIndex
            }
        }.map { $0.url }
    }

    /// Returns the highest-priority endpoint. Always non-nil because the
    /// selector requires at least one base URL at construction time.
    func primaryEndpoint() -> URL {
        orderedEndpoints().first ?? orderedURLs[0]
    }

    /// All known base URLs in their original configured order.
    nonisolated var configuredEndpoints: [URL] {
        orderedURLs
    }

    /// Records a successful probe or live request against `url`. The latency
    /// sample updates the EWMA and clears any failure / cooldown bookkeeping.
    func reportSuccess(_ url: URL, latencyMs: Double, serverID: String? = nil, serverVersion: String? = nil) {
        guard var state = states[url] else { return }
        let now = self.now()
        state.latencyMs = blendLatency(previous: state.latencyMs, sample: latencyMs)
        state.lastProbeAt = now
        state.lastSuccessAt = now
        state.consecutiveFailures = 0
        state.cooldownUntil = nil
        state.lastError = nil
        if let serverID, !serverID.isEmpty {
            state.serverID = serverID
        }
        if let serverVersion, !serverVersion.isEmpty {
            state.serverVersion = serverVersion
        }
        states[url] = state
    }

    /// Records a failed probe or live request. After `failureThreshold`
    /// consecutive failures, the endpoint enters cooldown using exponential
    /// backoff bounded by `maxCooldown`.
    func reportFailure(_ url: URL, error: Error) {
        guard var state = states[url] else { return }
        let now = self.now()
        state.consecutiveFailures += 1
        state.lastProbeAt = now
        state.lastError = error.localizedDescription
        if state.consecutiveFailures >= config.failureThreshold {
            let exponent = state.consecutiveFailures - config.failureThreshold
            let backoff = config.baseCooldown * pow(2.0, Double(exponent))
            let bounded = min(backoff, config.maxCooldown)
            state.cooldownUntil = now.addingTimeInterval(bounded)
        }
        states[url] = state
    }

    /// Concurrently probes every configured endpoint and updates internal
    /// state with the results. Failures are recorded but never thrown.
    func probeAll() async {
        let urls = orderedURLs
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                let prober = self.prober
                let timeout = config.probeTimeout
                let nonce = UUID().uuidString
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        let result = try await prober.probe(baseURL: url, nonce: nonce, timeout: timeout)
                        await self.reportSuccess(
                            url,
                            latencyMs: result.latencyMs,
                            serverID: result.serverID,
                            serverVersion: result.serverVersion
                        )
                    } catch {
                        await self.reportFailure(url, error: error)
                    }
                }
            }
        }
    }

    /// Diagnostic snapshot of every configured endpoint, in configured order.
    /// Suitable for rendering in a settings/diagnostics view.
    func snapshot() -> [CloudEndpointStatus] {
        orderedURLs.map { url in
            let state = states[url] ?? EndpointState()
            return CloudEndpointStatus(
                baseURL: url,
                latencyMs: state.latencyMs,
                lastProbeAt: state.lastProbeAt,
                lastSuccessAt: state.lastSuccessAt,
                consecutiveFailures: state.consecutiveFailures,
                cooldownUntil: state.cooldownUntil,
                serverID: state.serverID,
                serverVersion: state.serverVersion,
                lastError: state.lastError
            )
        }
    }

    private func blendLatency(previous: Double?, sample: Double) -> Double {
        guard let previous else { return sample }
        return config.ewmaAlpha * sample + (1.0 - config.ewmaAlpha) * previous
    }
}
