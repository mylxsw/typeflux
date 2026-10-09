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
            XCTAssertEqual(dict?["image_urls"] as? [String], ["https://cdn.example/image.jpg"])

            let payload = Data(#"{"code":"OK","data":{"id":"feedback-1","status":"pending"}}"#.utf8)
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        let response = try await FeedbackAPIService.submit(
            content: "  Please fix this  ",
            contact: " user@example.com ",
            imageURLs: ["https://cdn.example/image.jpg"],
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

    func testCreateImageUploadTargetPostsPresignRequest() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/feedback/uploads/presign")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")

            let body = try XCTUnwrap(request.httpBody)
            let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(dict?["filename"] as? String, "screen.jpg")
            XCTAssertEqual(dict?["content_type"] as? String, "image/jpeg")
            XCTAssertEqual(dict?["size_bytes"] as? Int, 123)

            let payload = Data(
                """
                {"code":"OK","data":{"type":"s3_presigned_post","method":"POST","url":"https://s3.example/upload","bucket":"bucket","region":"us-east-1","key":"feedback/screen.jpg","expires_at":1777960800,"max_size_bytes":5242880,"headers":{"x-test":"1"},"fields":{"key":"feedback/screen.jpg","policy":"abc"},"image_url":"https://cdn.example/feedback/screen.jpg","upload_id":"upload-1"}}
                """.utf8
            )
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: "screen.jpg",
            contentType: "image/jpeg",
            sizeBytes: 123,
            token: "token-1",
            executor: executor
        )

        XCTAssertEqual(target.url, "https://s3.example/upload")
        XCTAssertEqual(target.fields["policy"], "abc")
        XCTAssertEqual(target.imageURL, "https://cdn.example/feedback/screen.jpg")
    }

    func testCreateImageUploadTargetDecodesPresignedPutResponse() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            let payload = Data(
                """
                {"code":"OK","data":{"type":"s3_presigned_put","method":"PUT","url":"https://s3.example/upload?X-Amz-Signature=abc","bucket":"bucket","region":"apac","key":"feedback/screen.jpg","expires_at":1777960800,"max_size_bytes":5242880,"headers":{"Content-Type":"image/jpeg"},"fields":{},"image_url":"https://cdn.example/feedback/screen.jpg","upload_id":"upload-1"}}
                """.utf8
            )
            return (payload, Self.httpResponse(url: request.url!, status: 200))
        }
        let executor = makeExecutor(session: session)

        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: "screen.jpg",
            contentType: "image/jpeg",
            sizeBytes: 123,
            token: "token-1",
            executor: executor
        )

        XCTAssertEqual(target.type, "s3_presigned_put")
        XCTAssertEqual(target.method, "PUT")
        XCTAssertEqual(target.headers["Content-Type"], "image/jpeg")
        XCTAssertTrue(target.fields.isEmpty)
    }

    func testCreateImageUploadTargetMapsEmptyHTTPErrorBeforeDecoding() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            (Data(), Self.httpResponse(url: request.url!, status: 405))
        }
        let executor = makeExecutor(session: session)

        do {
            _ = try await FeedbackAPIService.createImageUploadTarget(
                filename: "screen.jpg",
                contentType: "image/jpeg",
                sizeBytes: 123,
                token: "token-1",
                executor: executor
            )
            XCTFail("Expected server error")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .serverError(code: "HTTP_405", message: nil))
        }
    }

    func testUploadImagePostsMultipartFieldsAndFileToPresignedTarget() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://s3.example/upload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-meta-purpose"), "feedback")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
                .contains("multipart/form-data; boundary=") == true)

            let body = try String(data: XCTUnwrap(request.httpBody), encoding: .utf8)
            XCTAssertTrue(body?.contains("name=\"key\"") == true)
            XCTAssertTrue(body?.contains("feedback/screen.jpg") == true)
            XCTAssertTrue(body?.contains("name=\"file\"; filename=\"screen.jpg\"") == true)
            XCTAssertTrue(body?.contains("Content-Type: image/jpeg") == true)
            XCTAssertTrue(body?.contains("image-data") == true)

            return (Data(), Self.httpResponse(url: request.url!, status: 204))
        }

        try await FeedbackAPIService.uploadImage(
            data: Data("image-data".utf8),
            filename: "screen.jpg",
            contentType: "image/jpeg",
            to: FeedbackUploadTarget(
                type: "s3_presigned_post",
                method: "POST",
                url: "https://s3.example/upload",
                bucket: "bucket",
                region: "us-east-1",
                key: "feedback/screen.jpg",
                expiresAt: 1_777_960_800,
                maxSizeBytes: 5_242_880,
                headers: ["x-amz-meta-purpose": "feedback"],
                fields: ["key": "feedback/screen.jpg", "policy": "abc"],
                imageURL: "https://cdn.example/feedback/screen.jpg",
                uploadID: "upload-1"
            ),
            session: session
        )
    }

    func testUploadImagePutsRawDataToPresignedPutTarget() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://s3.example/upload?X-Amz-Signature=abc")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.httpBody, Data("image-data".utf8))
            XCTAssertFalse(try String(data: XCTUnwrap(request.httpBody), encoding: .utf8)?
                .contains("multipart/form-data") == true)

            return (Data(), Self.httpResponse(url: request.url!, status: 200))
        }

        try await FeedbackAPIService.uploadImage(
            data: Data("image-data".utf8),
            filename: "screen.jpg",
            contentType: "image/jpeg",
            to: FeedbackUploadTarget(
                type: "s3_presigned_put",
                method: "PUT",
                url: "https://s3.example/upload?X-Amz-Signature=abc",
                bucket: "bucket",
                region: "apac",
                key: "feedback/screen.jpg",
                expiresAt: 1_777_960_800,
                maxSizeBytes: 5_242_880,
                headers: ["Content-Type": "image/jpeg"],
                fields: [:],
                imageURL: "https://cdn.example/feedback/screen.jpg",
                uploadID: "upload-1"
            ),
            session: session
        )
    }

    func testUploadImageIncludesStorageErrorBodyInServerError() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            let body = Data(
                """
                <?xml version="1.0" encoding="UTF-8"?><Error><Code>NotImplemented</Code><Message>Presigned post requests are not yet implemented</Message></Error>
                """.utf8
            )
            return (body, Self.httpResponse(url: request.url!, status: 501))
        }

        do {
            try await FeedbackAPIService.uploadImage(
                data: Data("image-data".utf8),
                filename: "screen.jpg",
                contentType: "image/jpeg",
                to: FeedbackUploadTarget(
                    type: "s3_presigned_post",
                    method: "POST",
                    url: "https://s3.example/upload",
                    bucket: "bucket",
                    region: "us-east-1",
                    key: "feedback/screen.jpg",
                    expiresAt: 1_777_960_800,
                    maxSizeBytes: 5_242_880,
                    headers: [:],
                    fields: ["key": "feedback/screen.jpg", "policy": "abc"],
                    imageURL: "https://cdn.example/feedback/screen.jpg",
                    uploadID: "upload-1"
                ),
                session: session
            )
            XCTFail("Expected upload failure")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(
                error,
                .serverError(
                    code: "UPLOAD_FAILED",
                    message: #"HTTP 501: <?xml version="1.0" encoding="UTF-8"?><Error><Code>NotImplemented</Code><Message>Presigned post requests are not yet implemented</Message></Error>"#
                )
            )
        }
    }

    func testUploadImagePropagatesTaskCancellation() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return (Data(), Self.httpResponse(url: request.url!, status: 204))
        }

        let task = Task {
            try await FeedbackAPIService.uploadImage(
                data: Data("image-data".utf8),
                filename: "screen.jpg",
                contentType: "image/jpeg",
                to: FeedbackUploadTarget(
                    type: "s3_presigned_post",
                    method: "POST",
                    url: "https://s3.example/upload",
                    bucket: "bucket",
                    region: "us-east-1",
                    key: "feedback/screen.jpg",
                    expiresAt: 1_777_960_800,
                    maxSizeBytes: 5_242_880,
                    headers: [:],
                    fields: ["key": "feedback/screen.jpg", "policy": "abc"],
                    imageURL: "https://cdn.example/feedback/screen.jpg",
                    uploadID: "upload-1"
                ),
                session: session
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancelled upload to throw CancellationError")
        } catch is CancellationError {
            let callCount = await session.callCount
            XCTAssertEqual(callCount, 1)
        }
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
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

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
            XCTAssertEqual(error.errorDescription, "The request was invalid. Please check the input and try again.")
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
            guard case let .networkError(message) = error else {
                XCTFail("Expected network error, got \(error)")
                return
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testSubmitFailsOverAfterHTTP500() async throws {
        let fallbackURL = try XCTUnwrap(URL(string: "https://api-fallback.example"))
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
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
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

// MARK: - Bounded proxy PUT contract

extension FeedbackAPIServiceTests {
    private static let proxyTargetJSON = """
    {"code":"OK","data":{"type":"bounded_proxy_put","method":"PUT","url":"/api/v1/feedback/uploads/upload-9","bucket":"feedback","region":"auto","key":"feedback-images/u/2026/10/upload-9/screen.png","expires_at":1777961100,"max_size_bytes":5242880,"headers":{"Content-Type":"image/png"},"fields":{},"image_url":"https://cdn.example/feedback-images/u/2026/10/upload-9/screen.png","upload_id":"upload-9"}}
    """

    private func proxyTarget(
        url: String,
        type: String = FeedbackAPIService.apiProxyUploadType,
        headers: [String: String] = ["Content-Type": "image/png"],
        issuingAPIBaseURL: URL? = URL(string: "https://api.example")
    ) -> FeedbackUploadTarget {
        FeedbackUploadTarget(
            type: type,
            method: "PUT",
            url: url,
            bucket: "feedback",
            region: "auto",
            key: "feedback-images/u/screen.png",
            expiresAt: 1_777_961_100,
            maxSizeBytes: 5_242_880,
            headers: headers,
            fields: [:],
            imageURL: "https://cdn.example/feedback-images/u/screen.png",
            uploadID: "upload-9",
            issuingAPIBaseURL: issuingAPIBaseURL
        )
    }

    func testRelativeProxyTargetResolvesAgainstIssuingFailoverEndpointWithSameBearer() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            if request.url?.host == "api.example" {
                return (Data(), Self.httpResponse(url: request.url!, status: 503))
            }
            if request.url?.path == "/api/v1/feedback/uploads/presign" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
                return (Data(Self.proxyTargetJSON.utf8), Self.httpResponse(url: request.url!, status: 200))
            }
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api-fallback.example/api/v1/feedback/uploads/upload-9"
            )
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Length"))
            XCTAssertEqual(request.httpBody, Data("png-bytes".utf8))
            return (Data(), Self.httpResponse(url: request.url!, status: 204))
        }
        let executor = makeExecutor(
            session: session,
            baseURLs: [baseURL, URL(string: "https://api-fallback.example")!]
        )

        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: "screen.png",
            contentType: "image/png",
            sizeBytes: 9,
            token: "token-1",
            executor: executor
        )
        XCTAssertEqual(target.type, "bounded_proxy_put")
        XCTAssertEqual(target.issuingAPIBaseURL?.host, "api-fallback.example")

        try await FeedbackAPIService.uploadImage(
            data: Data("png-bytes".utf8),
            filename: "screen.png",
            contentType: "image/png",
            to: target,
            token: "token-1",
            session: session
        )
        let hosts = await session.requestedHosts
        XCTAssertEqual(hosts, ["api.example", "api-fallback.example", "api-fallback.example"])
    }

    func testAbsoluteSameOriginProxyTargetCarriesBearer() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-2")
            return (Data(), Self.httpResponse(url: request.url!, status: 204))
        }

        try await FeedbackAPIService.uploadImage(
            data: Data("png".utf8),
            filename: "screen.png",
            contentType: "image/png",
            to: proxyTarget(url: "https://API.example:443/api/v1/feedback/uploads/upload-9"),
            token: "token-2",
            session: session
        )
        let calls = await session.callCount
        XCTAssertEqual(calls, 1)
    }

    func testAnonymousProxyUploadSendsNoAuthorization() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(), Self.httpResponse(url: request.url!, status: 204))
        }

        try await FeedbackAPIService.uploadImage(
            data: Data("png".utf8),
            filename: "screen.png",
            contentType: "image/png",
            to: proxyTarget(url: "/api/v1/feedback/uploads/upload-9"),
            token: "",
            session: session
        )
    }

    func testLegacyStorageTargetNeverReceivesBearerOrForwardedAuthorizationHeader() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.host, "s3.example")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(), Self.httpResponse(url: request.url!, status: 200))
        }

        try await FeedbackAPIService.uploadImage(
            data: Data("png".utf8),
            filename: "screen.png",
            contentType: "image/png",
            to: proxyTarget(
                url: "https://s3.example/upload?X-Amz-Signature=abc",
                type: "s3_presigned_put",
                headers: ["Content-Type": "image/png", "authorization": "Bearer leaked"]
            ),
            token: "token-1",
            session: session
        )
    }

    func testRejectsUnsafeUploadTargetsWithoutSendingRequests() async throws {
        let unsafeTargets = [
            // A proxy target must stay on the issuing API origin.
            proxyTarget(url: "https://evil.example/api/v1/feedback/uploads/upload-9"),
            // Protocol-relative URLs resolve to another host.
            proxyTarget(url: "//evil.example/upload", type: "s3_presigned_put"),
            // Different port or scheme is a different origin.
            proxyTarget(url: "https://api.example:8443/api/v1/feedback/uploads/upload-9"),
            proxyTarget(url: "http://api.example/api/v1/feedback/uploads/upload-9"),
            // Relative URLs need the issuing API origin.
            proxyTarget(url: "/api/v1/feedback/uploads/upload-9", issuingAPIBaseURL: nil),
            // Storage uploads must use HTTPS.
            proxyTarget(url: "http://s3.example/upload", type: "s3_presigned_put"),
            proxyTarget(url: "ftp://s3.example/upload", type: "s3_presigned_put"),
        ]
        let session = FeedbackStubSession()

        for target in unsafeTargets {
            do {
                try await FeedbackAPIService.uploadImage(
                    data: Data("png".utf8),
                    filename: "screen.png",
                    contentType: "image/png",
                    to: target,
                    token: "token-1",
                    session: session
                )
                XCTFail("Expected \(target.url) to be rejected")
            } catch let error as FeedbackAPIError {
                XCTAssertEqual(error, .invalidResponse, target.url)
            }
        }
        let calls = await session.callCount
        XCTAssertEqual(calls, 0)
    }

    func testProxyUploadMapsRevokedSessionAndConsumedTarget() async throws {
        for (status, expected) in [
            (401, FeedbackAPIError.unauthorized),
            (409, FeedbackAPIError.serverError(
                code: "UPLOAD_FAILED",
                message: #"HTTP 409: {"code":"FEEDBACK_UPLOAD_CONFLICT"}"#
            )),
        ] {
            let session = FeedbackStubSession()
            await session.setHandler { request in
                let body = status == 409 ? Data(#"{"code":"FEEDBACK_UPLOAD_CONFLICT"}"#.utf8) : Data()
                return (body, Self.httpResponse(url: request.url!, status: status))
            }
            do {
                try await FeedbackAPIService.uploadImage(
                    data: Data("png".utf8),
                    filename: "screen.png",
                    contentType: "image/png",
                    to: proxyTarget(url: "/api/v1/feedback/uploads/upload-9"),
                    token: "token-1",
                    session: session
                )
                XCTFail("Expected HTTP \(status) to fail")
            } catch let error as FeedbackAPIError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testStorageUnauthorizedIsAnUploadFailureNotASessionLoss() async throws {
        let session = FeedbackStubSession()
        await session.setHandler { request in
            (Data(), Self.httpResponse(url: request.url!, status: 401))
        }
        do {
            try await FeedbackAPIService.uploadImage(
                data: Data("png".utf8),
                filename: "screen.png",
                contentType: "image/png",
                to: proxyTarget(url: "https://s3.example/upload", type: "s3_presigned_put"),
                token: "token-1",
                session: session
            )
            XCTFail("Expected failure")
        } catch let error as FeedbackAPIError {
            XCTAssertEqual(error, .serverError(code: "UPLOAD_FAILED", message: "HTTP 401"))
        }
    }
}
