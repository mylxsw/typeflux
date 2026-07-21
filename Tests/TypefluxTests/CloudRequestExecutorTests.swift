@testable import Typeflux
import XCTest

final class CloudRequestExecutorTests: XCTestCase {
    private let urlA = URL(string: "https://a.example")!
    private let urlB = URL(string: "https://b.example")!
    private let urlC = URL(string: "https://c.example")!

    func testExecuteReturnsFirstSuccessfulEndpoint() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        let (data, response) = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(response.statusCode, 200)
        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA])
    }

    func testExecuteDoesNotMixBusinessRequestDurationIntoProbeLatency() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA], prober: NoOpProber())
        await selector.reportSuccess(urlA, latencyMs: 123)
        let executor = CloudRequestExecutor(selector: selector, session: session)

        _ = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        let status = await selector.snapshot()
        XCTAssertEqual(status[0].latencyMs, 123)
        XCTAssertEqual(status[0].consecutiveFailures, 0)
        XCTAssertNil(status[0].lastError)
    }

    func testExecuteAddsCloudClientHeaders() async throws {
        let session = StubSession()
        await session.setHandler { request in
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientIDField))
            XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientOSField), "macOS")
            return (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        _ = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }
    }

    func testExecuteFailsOverOnHTTP5xx() async throws {
        let session = StubSession()
        await session.setHandler { [urlA] request in
            if request.url?.host == urlA.host {
                return (Data("server error".utf8), Self.httpResponse(url: request.url!, status: 503))
            } else {
                return (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
            }
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        let (data, response) = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(response.statusCode, 200)
        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA, urlB])
    }

    func testExecuteDoesNotFailoverOnHTTP4xx() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("nope".utf8), Self.httpResponse(url: request.url!, status: 404))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        let (data, response) = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "nope")
        XCTAssertEqual(response.statusCode, 404)
        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA])
    }

    func testExecuteFailsOverOnTransportError() async throws {
        let session = StubSession()
        await session.setHandler { [urlA] request in
            if request.url?.host == urlA.host {
                throw URLError(.notConnectedToInternet)
            }
            return (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        let (data, response) = try await executor.execute { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(response.statusCode, 200)
        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA, urlB])
    }

    func testExecuteDoesNotFailoverOrReportEndpointFailureOnBillingError() async throws {
        let billingError = TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nil)
        let session = StubSession()
        await session.setHandler { _ in
            throw billingError
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        do {
            _ = try await executor.execute(apiPath: "/api/v1/asr/token") { base in
                URLRequest(url: base.appendingPathComponent("api/v1/asr/token"))
            }
            XCTFail("Expected billing error")
        } catch let error as TypefluxCloudBillingError {
            XCTAssertEqual(error, billingError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA])
        let status = await selector.snapshot()
        XCTAssertEqual(status[0].consecutiveFailures, 0)
        XCTAssertNil(status[0].lastError)
        XCTAssertEqual(status[1].consecutiveFailures, 0)
        XCTAssertNil(status[1].lastError)
    }

    func testExecuteThrowsAllEndpointsFailedWhenEveryAttemptFails() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("err".utf8), Self.httpResponse(url: request.url!, status: 502))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)

        do {
            _ = try await executor.execute { base in
                URLRequest(url: base.appendingPathComponent("api/v1/me"))
            }
            XCTFail("Expected allEndpointsFailed")
        } catch let CloudRequestExecutorError.allEndpointsFailed(lastError) {
            // Last error should reference an HTTP 5xx failure.
            let nsErr = lastError as NSError
            XCTAssertEqual(nsErr.domain, "CloudRequestExecutor")
            XCTAssertEqual(nsErr.code, 502)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlA, urlB])
    }

    func testExecuteKeepsPrimaryFirstForNonSpecialAPIEvenWhenBackupIsFaster() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        // Pre-seed urlA with a high latency. Non-special APIs should still
        // treat the first configured endpoint as primary.
        await selector.reportSuccess(urlA, latencyMs: 1000)
        await selector.reportSuccess(urlB, latencyMs: 50)

        let executor = CloudRequestExecutor(selector: selector, session: session)
        _ = try await executor.execute(apiPath: "/api/v1/me") { base in
            URLRequest(url: base.appendingPathComponent("api/v1/me"))
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls.first, urlA)
    }

    func testExecuteUsesLatencyOptimizedRoutingForChatAPI() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        await selector.reportSuccess(urlA, latencyMs: 1000)
        await selector.reportSuccess(urlB, latencyMs: 50)

        let executor = CloudRequestExecutor(selector: selector, session: session)
        _ = try await executor.execute(apiPath: "/api/v1/chat/completions") { base in
            URLRequest(url: base.appendingPathComponent("api/v1/chat/completions"))
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls.first, urlB)
    }

    func testExecuteUsesLatencyOptimizedRoutingForASRAPI() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        await selector.reportSuccess(urlA, latencyMs: 1000)
        await selector.reportSuccess(urlB, latencyMs: 50)

        let executor = CloudRequestExecutor(selector: selector, session: session)
        _ = try await executor.execute(apiPath: "/api/v1/asr/token") { base in
            URLRequest(url: base.appendingPathComponent("api/v1/asr/token"))
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls.first, urlB)
    }

    func testExecuteBuildsRequestOnlyForAttemptedEndpoints() async throws {
        let session = StubSession()
        await session.setHandler { request in
            (Data("ok".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let selector = CloudEndpointSelector(baseURLs: [urlA, urlB], prober: NoOpProber())
        await selector.reportSuccess(urlA, latencyMs: 1000)
        await selector.reportSuccess(urlB, latencyMs: 50)

        let counter = BuildCounter()
        let executor = CloudRequestExecutor(selector: selector, session: session)
        _ = try await executor.execute(apiPath: "/api/v1/chat/completions") { base in
            counter.increment()
            return URLRequest(url: base.appendingPathComponent("api/v1/chat/completions"))
        }

        let calls = await session.callOrder
        XCTAssertEqual(calls, [urlB])
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Helpers

    private static func httpResponse(url: URL, status: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private actor StubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handler: Handler = { _ in
        (Data(), URLResponse())
    }

    private(set) var callOrder: [URL] = []

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url {
            // Record only the host-level base for assertion clarity.
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = url.host
            if let port = url.port { components.port = port }
            if let baseURL = components.url {
                callOrder.append(baseURL)
            }
        }
        return try await handler(request)
    }
}

private struct NoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        throw CloudEndpointProbeError.timedOut
    }
}

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
