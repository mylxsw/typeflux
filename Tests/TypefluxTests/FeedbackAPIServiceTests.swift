@testable import Typeflux
import XCTest

final class FeedbackAPIServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://api.example")!

    func testCreateFeedbackRequestEncodesSnakeCaseImageURLs() throws {
        let request = CreateFeedbackRequest(
            content: "App crashed",
            contact: "user@example.com",
            imageURLs: ["https://example.com/image.png"]
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["content"] as? String, "App crashed")
        XCTAssertEqual(dict?["contact"] as? String, "user@example.com")
        XCTAssertEqual(dict?["image_urls"] as? [String], ["https://example.com/image.png"])
        XCTAssertNil(dict?["imageURLs"])
    }

    func testSubmitPostsFeedbackToCloudEndpoint() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")

            let body = try XCTUnwrap(request.httpBody)
            let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(dict?["content"] as? String, "Please fix this")
            XCTAssertEqual(dict?["contact"] as? String, "user@example.com")

            let payload = Data(#"{"code":"OK","data":{"id":"feedback-1","status":"pending"}}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        let response = try await FeedbackAPIService.submit(
            content: "  Please fix this  ",
            contact: " user@example.com ",
            token: "token-1",
            executor: executor
        )

        XCTAssertEqual(response, FeedbackSubmissionResponse(id: "feedback-1", status: "pending"))
    }

    func testSubmitOmitsAuthorizationAndBlankContactForAnonymousFeedback() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = try XCTUnwrap(request.httpBody)
            let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(dict?["content"] as? String, "Anonymous report")
            XCTAssertNil(dict?["contact"])

            let payload = Data(#"{"code":"OK","data":{"id":"feedback-2","status":"pending"}}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        let response = try await FeedbackAPIService.submit(
            content: "Anonymous report",
            contact: "   ",
            token: nil,
            executor: executor
        )

        XCTAssertEqual(response, FeedbackSubmissionResponse(id: "feedback-2", status: "pending"))
    }

    func testSubmitRejectsEmptyContentBeforeNetworkRequest() async throws {
        let session = FeedbackStubSession()
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.submit(content: "   ", contact: nil, executor: executor)
            XCTFail("Expected empty content error")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .emptyContent)
        }

        let callCount = await session.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testSubmitMapsUnauthorizedResponse() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            let payload = Data(#"{"code":"UNAUTHORIZED","message":"Sign in required","data":null}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 401))
        }
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.submit(content: "Please fix this", contact: nil, executor: executor)
            XCTFail("Expected unauthorized error")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testSubmitMapsServerErrorMessage() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            let payload = Data(#"{"code":"VALIDATION_ERROR","message":"Content is too long","data":null}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 400))
        }
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.submit(content: "Please fix this", contact: nil, executor: executor)
            XCTFail("Expected server error")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .serverError(code: "VALIDATION_ERROR", message: "Content is too long"))
        }
    }

    func testSubmitMapsInvalidJSONToInvalidResponse() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            (Data("not json".utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.submit(content: "Please fix this", contact: nil, executor: executor)
            XCTFail("Expected invalid response error")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testSubmitMapsNetworkFailure() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.submit(content: "Please fix this", contact: nil, executor: executor)
            XCTFail("Expected network error")
        } catch let error as FeedbackAPIError {
            guard case .networkError(let message) = error else {
                XCTFail("Expected network error, got \(error)")
                return
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testSubmitFailsOverAfterHTTP500() async throws {
        let fallbackURL = URL(string: "https://api-fallback.example")!
        let session = FeedbackStubSession()
        await session.setHandler { request in
            if request.url?.host == "api.example" {
                let payload = Data(#"{"code":"SERVER_ERROR","message":"Try later","data":null}"#.utf8)
                return (payload, Self.httpResponse(url: request.url!, status: 500))
            }

            let payload = Data(#"{"code":"OK","data":{"id":"feedback-3","status":"pending"}}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session, baseURLs: [baseURL, fallbackURL])

        let response = try await FeedbackAPIService.submit(
            content: "Please fix this",
            contact: nil,
            executor: executor
        )

        XCTAssertEqual(response, FeedbackSubmissionResponse(id: "feedback-3", status: "pending"))
        let requestedHosts = await session.requestedHosts
        XCTAssertEqual(requestedHosts, ["api.example", "api-fallback.example"])
    }

    private func makeExecutor(
        session: FeedbackStubSession,
        baseURLs: [URL]? = nil
    ) -> CloudRequestExecutor {
        let selector = CloudEndpointSelector(baseURLs: baseURLs ?? [baseURL], prober: FeedbackNoOpProber())
        return CloudRequestExecutor(selector: selector, session: session)
    }
}

private actor FeedbackStubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handler: Handler?
    private(set) var callCount = 0
    private(set) var requestedHosts: [String] = []

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        if let host = request.url?.host {
            requestedHosts.append(host)
        }
        guard let handler else {
            throw URLError(.badServerResponse)
        }
        return try await handler(request)
    }
}

private struct FeedbackNoOpProber: CloudEndpointProbing {
    func probe(baseURL: URL, nonce: String, timeout: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

private extension FeedbackAPIServiceTests {
    static func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
