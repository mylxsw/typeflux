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
            return "No Typeflux Cloud endpoints are configured."
        case .allEndpointsFailed(let lastError):
            return "All Typeflux Cloud endpoints failed: \(lastError.localizedDescription)"
        case .invalidResponse:
            return "Received an invalid HTTP response."
        }
    }
}

/// Loads/Saves data over HTTP. Wraps `URLSession` so tests can inject stubs.
protocol CloudHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CloudHTTPSession {}

/// Executes an HTTP request against the highest-priority Typeflux Cloud
/// endpoint, falling back to additional endpoints when the active one returns
/// a transport error or HTTP 5xx. Latency samples and failures are reported
/// back into the selector so future calls converge on the lowest-latency host.
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

    /// Returns the best base URL to use for a one-off request that the caller
    /// will issue itself (for example, when the request lifecycle is owned by a
    /// component that cannot easily route through `execute`).
    func primaryEndpoint() async -> URL {
        await selector.primaryEndpoint()
    }

    /// Executes `build(baseURL)` against each healthy endpoint in priority
    /// order. Network errors and HTTP 5xx responses cause failover; other HTTP
    /// status codes are returned to the caller without rotating endpoints.
    func execute(
        build: @Sendable (URL) -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let endpoints = await selector.orderedEndpoints()
        guard !endpoints.isEmpty else {
            throw CloudRequestExecutorError.noEndpointsAvailable
        }

        var lastError: Error?
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            let request = build(endpoint)
            let start = ContinuousClock.now

            do {
                let (data, response) = try await session.data(for: request)
                let elapsed = ContinuousClock.now - start
                guard let http = response as? HTTPURLResponse else {
                    throw CloudRequestExecutorError.invalidResponse
                }
                if (500..<600).contains(http.statusCode) {
                    let httpError = NSError(
                        domain: "CloudRequestExecutor",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(endpoint.absoluteString)"]
                    )
                    await selector.reportFailure(endpoint, error: httpError)
                    lastError = httpError
                    logger.error("HTTP \(http.statusCode) from \(endpoint.absoluteString); will try next endpoint (\(index + 1)/\(endpoints.count))")
                    continue
                }
                let latency = durationToMilliseconds(elapsed)
                await selector.reportSuccess(endpoint, latencyMs: latency)
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await selector.reportFailure(endpoint, error: error)
                lastError = error
                logger.error("Endpoint \(endpoint.absoluteString) failed: \(error.localizedDescription); will try next (\(index + 1)/\(endpoints.count))")
                continue
            }
        }

        throw CloudRequestExecutorError.allEndpointsFailed(lastError: lastError ?? CloudRequestExecutorError.noEndpointsAvailable)
    }

    private func durationToMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let secondsAsMs = Double(components.seconds) * 1000.0
        let attoAsMs = Double(components.attoseconds) / 1_000_000_000_000_000.0
        return secondsAsMs + attoAsMs
    }
}
