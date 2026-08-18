@testable import Typeflux
import XCTest

final class CloudEndpointProberTests: XCTestCase {
    override func tearDown() {
        ProberURLProtocol.reset()
        super.tearDown()
    }

    func testProbeAppendsApiV1PingPathAndNonceQuery() async throws {
        ProberURLProtocol.requestInspector = { request in
            guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                XCTFail("missing URL")
                return
            }
            XCTAssertEqual(components.path, "/api/v1/ping")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "nonce" })?.value, "abc-123")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientIDField))
        }
        ProberURLProtocol.responder = { request in
            let body = #"{"code":"OK","data":{"pong":true,"nonce":"abc-123","server_id":"s1","server_time_ms":1,"version":"v1"}}"#
            return Self.makeResponse(url: request.url!, status: 200, body: body)
        }

        let prober = HTTPCloudEndpointProber(session: stubSession())
        let result = try await prober.probe(
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            nonce: "abc-123",
            timeout: 1
        )

        XCTAssertTrue(result.nonceMatches)
        XCTAssertEqual(result.serverID, "s1")
        XCTAssertEqual(result.serverVersion, "v1")
        XCTAssertGreaterThanOrEqual(result.latencyMs, 0)
    }

    func testProbeRespectsBasePathInBaseURL() async throws {
        ProberURLProtocol.requestInspector = { request in
            XCTAssertEqual(request.url?.path, "/edge/api/v1/ping")
        }
        ProberURLProtocol.responder = { request in
            let body = #"{"code":"OK","data":{"pong":true,"nonce":"n","server_id":null,"server_time_ms":1,"version":""}}"#
            return Self.makeResponse(url: request.url!, status: 200, body: body)
        }

        let prober = HTTPCloudEndpointProber(session: stubSession())
        _ = try await prober.probe(
            baseURL: XCTUnwrap(URL(string: "https://example.com/edge/")),
            nonce: "n",
            timeout: 1
        )
    }

    func testProbeIncludesOptionalCloudAccessToken() async throws {
        ProberURLProtocol.requestInspector = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        }
        ProberURLProtocol.responder = { request in
            let body = #"{"code":"OK","data":{"pong":true,"nonce":"n","server_id":"s1","server_time_ms":1,"version":"v1"}}"#
            return Self.makeResponse(url: request.url!, status: 200, body: body)
        }

        let prober = HTTPCloudEndpointProber(
            session: stubSession(),
            accessTokenProvider: { "test-access-token" }
        )
        _ = try await prober.probe(
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            nonce: "n",
            timeout: 1
        )
    }

    func testProbeThrowsOnNonceMismatch() async throws {
        ProberURLProtocol.responder = { request in
            let body = #"{"code":"OK","data":{"pong":true,"nonce":"DIFFERENT","server_id":"s","server_time_ms":1,"version":"v"}}"#
            return Self.makeResponse(url: request.url!, status: 200, body: body)
        }

        let prober = HTTPCloudEndpointProber(session: stubSession())
        do {
            _ = try await prober.probe(
                baseURL: XCTUnwrap(URL(string: "https://example.com")),
                nonce: "expected",
                timeout: 1
            )
            XCTFail("Expected nonceMismatch")
        } catch CloudEndpointProbeError.nonceMismatch {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProbeThrowsOnNon2xxStatus() async throws {
        ProberURLProtocol.responder = { request in
            Self.makeResponse(url: request.url!, status: 503, body: "")
        }

        let prober = HTTPCloudEndpointProber(session: stubSession())
        do {
            _ = try await prober.probe(
                baseURL: XCTUnwrap(URL(string: "https://example.com")),
                nonce: "n",
                timeout: 1
            )
            XCTFail("Expected httpStatus")
        } catch let CloudEndpointProbeError.httpStatus(code) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProbeThrowsDecodingErrorForGarbageBody() async throws {
        ProberURLProtocol.responder = { request in
            Self.makeResponse(url: request.url!, status: 200, body: "not json")
        }

        let prober = HTTPCloudEndpointProber(session: stubSession())
        do {
            _ = try await prober.probe(
                baseURL: XCTUnwrap(URL(string: "https://example.com")),
                nonce: "n",
                timeout: 1
            )
            XCTFail("Expected decoding")
        } catch CloudEndpointProbeError.decoding {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHealthProbeUsesASRHealthEndpointAndMeasuresLatency() async throws {
        ProberURLProtocol.requestInspector = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/healthz")
            XCTAssertNil(request.url?.query)
        }
        ProberURLProtocol.responder = { request in
            Self.makeResponse(url: request.url!, status: 200, body: #"{"code":"OK","data":{"ok":true}}"#)
        }

        let prober = HTTPHealthEndpointProber(session: stubSession())
        let result = try await prober.probe(
            baseURL: XCTUnwrap(URL(string: "https://asr.example.com")),
            nonce: "unused",
            timeout: 1
        )

        XCTAssertGreaterThanOrEqual(result.latencyMs, 0)
        XCTAssertTrue(result.nonceMatches)
    }

    func testHealthProbeRejectsUnhealthyPayload() async throws {
        ProberURLProtocol.responder = { request in
            Self.makeResponse(url: request.url!, status: 200, body: #"{"code":"OK","data":{"ok":false}}"#)
        }

        let prober = HTTPHealthEndpointProber(session: stubSession())
        do {
            _ = try await prober.probe(
                baseURL: XCTUnwrap(URL(string: "https://asr.example.com")),
                nonce: "unused",
                timeout: 1
            )
            XCTFail("Expected decoding error")
        } catch CloudEndpointProbeError.decoding {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProberURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeResponse(url: URL, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

// MARK: - URLProtocol stub

final class ProberURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestInspector: (@Sendable (URLRequest) -> Void)?

    static func reset() {
        responder = nil
        requestInspector = nil
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestInspector?(request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
