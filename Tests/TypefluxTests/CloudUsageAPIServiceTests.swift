@testable import Typeflux
import XCTest

final class CloudUsageAPIServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://api.example")!

    func testFetchCurrentPeriodStatsBuildsAuthenticatedRequestAndDecodesEnvelopeResponse() async throws {
        let session = CloudUsageStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/usage/current-period/stats")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            let body = """
            {
              "code": "OK",
              "data": {
                "period_start": "2026-05-01T00:00:00Z",
                "period_end": "2026-06-01T00:00:00Z",
                "stats": {
                  "asr_count": 3,
                  "asr_audio_duration_ms": 125000,
                  "asr_output_chars": 420,
                  "chat_count": 2,
                  "chat_output_chars": 180,
                  "chat_input_tokens": 1000,
                  "chat_output_tokens": 240,
                  "chat_total_tokens": 1240
                },
                "credits": {
                  "limit": 2000,
                  "used": 48,
                  "remaining": 1952,
                  "unlimited": false
                }
              }
            }
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.fetchCurrentPeriodStats(token: "token-1")

        XCTAssertEqual(snapshot.periodStart, "2026-05-01T00:00:00Z")
        XCTAssertEqual(snapshot.periodEnd, "2026-06-01T00:00:00Z")
        XCTAssertEqual(snapshot.stats.asrCount, 3)
        XCTAssertEqual(snapshot.stats.asrAudioDurationMs, 125_000)
        XCTAssertEqual(snapshot.stats.chatTotalTokens, 1240)
        XCTAssertEqual(snapshot.stats.totalRequests, 5)
        XCTAssertEqual(snapshot.credits, CloudCreditSummary(limit: 2000, used: 48, remaining: 1952, unlimited: false))
    }

    func testFetchCurrentPeriodBreakdownSendsTheTimeZoneAndDecodesTheEnvelope() async throws {
        let session = CloudUsageStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/usage/current-period/breakdown")
            XCTAssertEqual(request.url?.query, "tz=America/New_York")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            let body = """
            {"code":"OK","data":{"period_start":"2026-10-01T00:00:00Z","period_end":"2026-11-01T00:00:00Z",
             "timezone":"America/New_York","days":[{"date":"2026-10-01","voice":5,"rewrite":2,"ask":1}],
             "voice":5,"rewrite":2,"ask":1}}
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let breakdown = try await makeService(session: session)
            .fetchCurrentPeriodBreakdown(token: "token-1", timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(breakdown.timezone, "America/New_York")
        XCTAssertEqual(breakdown.days.first?.total, 8)
        XCTAssertEqual(breakdown.total, 8)
    }

    /// A server without the endpoint fails the request (the executor reports
    /// 5xx as an endpoint failure); the account page then hides the charts.
    func testFetchCurrentPeriodBreakdownSurfacesUnsupportedServers() async {
        let session = CloudUsageStubSession()
        await session.setHandler { request in
            let body = #"{"code":"NOT_IMPLEMENTED","message":"usage breakdown is not available"}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 501))
        }
        do {
            _ = try await makeService(session: session).fetchCurrentPeriodBreakdown(token: "t", timeZone: .current)
            XCTFail("Expected an error")
        } catch AuthError.networkError {
            // Expected.
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    private func makeService(session: CloudUsageStubSession) -> CloudUsageAPIService {
        let selector = CloudEndpointSelector(baseURLs: [baseURL], prober: CloudUsageNoOpProber())
        return CloudUsageAPIService(executor: CloudRequestExecutor(selector: selector, session: session))
    }

    private static func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private actor CloudUsageStubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handler: Handler?

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let handler else {
            throw URLError(.badServerResponse)
        }
        return try await handler(request)
    }
}

private struct CloudUsageNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}
