import Foundation
import os

struct TypefluxASRPublicConfig: Equatable, Sendable {
    let realtimeServers: [URL]
}

protocol TypefluxASRPublicConfigClient: Sendable {
    func fetchPublicConfig() async throws -> TypefluxASRPublicConfig
}

struct TypefluxASRPublicConfigHTTPClient: TypefluxASRPublicConfigClient {
    private let executor: CloudRequestExecutor

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) {
        self.executor = executor
    }

    func fetchPublicConfig() async throws -> TypefluxASRPublicConfig {
        let (data, response) = try await executor.execute(apiPath: "/api/v1/info") { baseURL in
            var request = URLRequest(url: AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/info"))
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            return request
        }

        let envelope: APIResponse<InfoResponse>
        do {
            envelope = try JSONDecoder().decode(APIResponse<InfoResponse>.self, from: data)
        } catch {
            throw TypefluxOfficialASRRoutingError.invalidResponse
        }

        guard (200 ..< 300).contains(response.statusCode), envelope.code == "OK", let payload = envelope.data else {
            throw TypefluxOfficialASRRoutingError.serverError(code: envelope.code, message: envelope.message)
        }

        return TypefluxASRPublicConfig(
            realtimeServers: TypefluxASRServerURLNormalizer.normalizedURLs(from: payload.realtimeServers)
        )
    }
}

private struct InfoResponse: Decodable {
    let realtimeServers: [String]

    enum CodingKeys: String, CodingKey {
        case realtimeServers = "realtime_servers"
    }
}

protocol TypefluxASRServerProviding: Sendable {
    func refreshPublicConfig() async
    func orderedServers(preferred: [URL]) async -> [URL]
    func reportFailure(_ url: URL, error: Error) async
}

enum TypefluxASRServerURLNormalizer {
    static func normalizedURLs(from rawServers: [String]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for rawServer in rawServers {
            guard let normalized = normalizedURL(from: rawServer) else {
                continue
            }
            let key = normalized.absoluteString
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func normalizedURL(from rawServer: String) -> URL? {
        let trimmed = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

actor TypefluxASRServerRegistry: TypefluxASRServerProviding {
    static let shared = TypefluxASRServerRegistry()

    private let publicConfigClient: TypefluxASRPublicConfigClient
    private let prober: CloudEndpointProbing
    private let config: CloudEndpointSelectorConfig
    private let userDefaults: UserDefaults
    private let cacheKey: String
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxASRServerRegistry")

    private var selector: CloudEndpointSelector?
    private var cachedServers: [URL]

    init(
        publicConfigClient: TypefluxASRPublicConfigClient = TypefluxASRPublicConfigHTTPClient(),
        prober: CloudEndpointProbing = HTTPHealthEndpointProber(),
        config: CloudEndpointSelectorConfig = .default,
        userDefaults: UserDefaults = .standard,
        cacheKey: String = "TypefluxASRRealtimeServers"
    ) {
        self.publicConfigClient = publicConfigClient
        self.prober = prober
        self.config = config
        self.userDefaults = userDefaults
        self.cacheKey = cacheKey
        cachedServers = TypefluxASRServerURLNormalizer.normalizedURLs(
            from: userDefaults.stringArray(forKey: cacheKey) ?? []
        )
    }

    func refreshPublicConfig() async {
        do {
            let config = try await publicConfigClient.fetchPublicConfig()
            await replaceServersAndProbe(config.realtimeServers, forceProbe: true)
        } catch {
            logger.error("Failed to refresh Typeflux ASR public config: \(error.localizedDescription)")
            await probeAllAvailable()
        }
    }

    func orderedServers(preferred: [URL]) async -> [URL] {
        let normalizedPreferred = TypefluxASRServerURLNormalizer.normalizedURLs(
            from: preferred.map(\.absoluteString)
        )
        if !normalizedPreferred.isEmpty {
            await replaceServersAndProbe(normalizedPreferred, forceProbe: false)
        } else if selector == nil, !cachedServers.isEmpty {
            selector = makeSelector(for: cachedServers)
        }
        guard let selector else { return [] }
        return await selector.latencyOptimizedEndpoints()
    }

    func reportFailure(_ url: URL, error: Error) async {
        guard let selector else { return }
        await selector.reportFailure(url, error: error)
    }

    func snapshot() async -> [CloudEndpointStatus] {
        if selector == nil, !cachedServers.isEmpty {
            selector = makeSelector(for: cachedServers)
        }
        guard let selector else { return [] }
        return await selector.snapshot()
    }

    func probeAllAvailable() async {
        if selector == nil, !cachedServers.isEmpty {
            selector = makeSelector(for: cachedServers)
        }
        await selector?.probeAll()
    }

    private func replaceServersAndProbe(_ servers: [URL], forceProbe: Bool) async {
        let normalized = TypefluxASRServerURLNormalizer.normalizedURLs(from: servers.map(\.absoluteString))
        guard !normalized.isEmpty else { return }
        let serversChanged = normalized != cachedServers || selector == nil
        if serversChanged {
            cachedServers = normalized
            userDefaults.set(normalized.map(\.absoluteString), forKey: cacheKey)
            selector = makeSelector(for: normalized)
        }
        if serversChanged || forceProbe {
            await selector?.probeAll()
        }
    }

    private func makeSelector(for servers: [URL]) -> CloudEndpointSelector {
        CloudEndpointSelector(
            baseURLs: servers,
            prober: prober,
            config: config,
            preferredEndpoint: { CloudServerPreferences.shared.preferredASRURL }
        )
    }
}

@MainActor
final class TypefluxASRPublicConfigRefreshScheduler {
    private let registry: TypefluxASRServerProviding
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(
        registry: TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        interval: TimeInterval = 60 * 60
    ) {
        self.registry = registry
        self.interval = interval
    }

    func start() {
        stop()
        let registry = registry
        let interval = interval
        task = Task.detached(priority: .utility) {
            await registry.refreshPublicConfig()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await registry.refreshPublicConfig()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
