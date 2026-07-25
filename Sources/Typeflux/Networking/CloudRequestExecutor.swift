import Foundation
import os

/// Errors raised by `CloudRequestExecutor` when the failover chain is exhausted
/// or the caller-supplied request cannot be built.
enum CloudRequestExecutorError: LocalizedError {
    case noEndpointsAvailable
    case allEndpointsFailed(lastError: Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noEndpointsAvailable:
            "No Typeflux Cloud endpoints are configured."
        case let .allEndpointsFailed(lastError):
            "All Typeflux Cloud endpoints failed: \(lastError.localizedDescription)"
        case .invalidResponse:
            "Received an invalid HTTP response."
        }
    }
}

/// Loads/Saves data over HTTP. Wraps `URLSession` so tests can inject stubs.
protocol CloudHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CloudHTTPSession {}

/// Routing policy for Typeflux Cloud requests.
enum CloudEndpointRoutingStrategy: Sendable, Equatable {
    /// Selects latency-optimized routing only for APIs that are explicitly
    /// allowed to use the fastest endpoint; all other APIs use primary-first.
    case automatic
    /// Always try the first configured server before backups.
    case primaryFirst
    /// Try endpoints in measured latency order.
    case latencyOptimized
}

/// Executes an HTTP request against the highest-priority Typeflux Cloud
/// endpoint, falling back to additional endpoints when the active one returns
/// a transport error or HTTP 5xx. When the caller provides an API path, only
/// `/api/v1/chat/` and `/api/v1/asr/` use latency-optimized routing; all other
/// APIs keep the first configured server as the primary endpoint.
struct CloudRequestExecutor: Sendable {
    let selector: CloudEndpointSelector
    let session: CloudHTTPSession

    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudRequestExecutor")

    init(
        selector: CloudEndpointSelector = CloudEndpointRegistry.shared,
        session: CloudHTTPSession = URLSession.shared
    ) {
        self.selector = selector
        self.session = session
    }

    /// Returns the configured primary base URL to use for a one-off request
    /// that the caller will issue itself.
    func configuredPrimaryEndpoint() async -> URL {
        await selector.configuredPrimaryEndpoint()
    }

    /// Returns the best base URL to use for a latency-sensitive one-off request
    /// that the caller will issue itself (for example, when the request
    /// lifecycle is owned by a component that cannot easily route through
    /// `execute`).
    func primaryEndpoint() async -> URL {
        await selector.latencyOptimizedEndpoint()
    }

    /// Executes `build(baseURL)` against each eligible endpoint in priority
    /// order. Network errors and HTTP 5xx responses cause failover; other HTTP
    /// status codes are returned to the caller without rotating endpoints.
    func execute(
        apiPath: String? = nil,
        routingStrategy: CloudEndpointRoutingStrategy = .automatic,
        build: @Sendable (URL) -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let resolvedStrategy = resolveRoutingStrategy(routingStrategy, apiPath: apiPath)
        let endpoints: [URL] = switch resolvedStrategy {
        case .automatic:
            await selector.primaryFirstEndpoints()
        case .primaryFirst:
            await selector.primaryFirstEndpoints()
        case .latencyOptimized:
            await selector.latencyOptimizedEndpoints()
        }
        guard !endpoints.isEmpty else {
            throw CloudRequestExecutorError.noEndpointsAvailable
        }

        var lastError: Error?
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            var request = build(endpoint)
            TypefluxCloudRequestHeaders.applyClientInfo(to: &request)

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudRequestExecutorError.invalidResponse
                }
                if (500 ..< 600).contains(http.statusCode) {
                    let httpError = NSError(
                        domain: "CloudRequestExecutor",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(endpoint.absoluteString)"]
                    )
                    await selector.reportFailure(endpoint, error: httpError)
                    lastError = httpError
                    logger
                        .error(
                            "HTTP \(http.statusCode) from \(endpoint.absoluteString); will try next endpoint (\(index + 1)/\(endpoints.count))"
                        )
                    continue
                }
                await selector.reportRequestSuccess(endpoint)
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error where TypefluxCloudBillingError.fromError(error) != nil {
                throw TypefluxCloudBillingError.fromError(error) ?? error
            } catch {
                await selector.reportFailure(endpoint, error: error)
                lastError = error
                logger
                    .error(
                        "Endpoint \(endpoint.absoluteString) failed: \(error.localizedDescription); will try next (\(index + 1)/\(endpoints.count))"
                    )
                continue
            }
        }

        throw CloudRequestExecutorError
            .allEndpointsFailed(lastError: lastError ?? CloudRequestExecutorError.noEndpointsAvailable)
    }

    private func resolveRoutingStrategy(
        _ strategy: CloudEndpointRoutingStrategy,
        apiPath: String?
    ) -> CloudEndpointRoutingStrategy {
        guard strategy == .automatic else { return strategy }
        guard let path = apiPath else { return .primaryFirst }
        return Self.isLatencyOptimizedAPIPath(path) ? .latencyOptimized : .primaryFirst
    }

    static func isLatencyOptimizedAPIPath(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return normalized == "/api/v1/chat"
            || normalized.hasPrefix("/api/v1/chat/")
            || normalized.contains("/api/v1/chat/")
            || normalized == "/api/v1/asr"
            || normalized.hasPrefix("/api/v1/asr/")
            || normalized.contains("/api/v1/asr/")
    }

}
