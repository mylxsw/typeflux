@testable import Typeflux
import XCTest

final class BillingAPIServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://api.example")!

    func testFetchSubscriptionBuildsAuthenticatedRequestAndDecodesFlatResponse() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/billing/subscription")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            let body = """
            {
              "code": "OK",
              "data": {
                "billing_enabled": true,
                "plan_code": "typeflux_cloud_monthly",
                "status": "active",
                "current_period_start": "2026-05-01T00:00:00Z",
                "current_period_end": "2026-06-01T00:00:00Z",
                "cancel_at_period_end": false,
                "entitled": true
              }
            }
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.fetchSubscription(token: "token-1")

        XCTAssertEqual(snapshot.planCode, "typeflux_cloud_monthly")
        XCTAssertEqual(snapshot.status, "active")
        XCTAssertEqual(snapshot.currentPeriodStart, "2026-05-01T00:00:00Z")
        XCTAssertTrue(snapshot.billingEnabled)
        XCTAssertTrue(snapshot.shouldShowSubscriptionDetails)
        XCTAssertFalse(snapshot.treatsCreditsAsFreeAllowance)
        XCTAssertTrue(snapshot.entitled)
        XCTAssertTrue(snapshot.hasSubscription)
    }

    func testFetchSubscriptionDecodesNestedPlanResponse() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            let body = """
            {
              "code": "OK",
              "data": {
                "subscription": {
                  "plan_code": "typeflux_cloud_monthly",
                  "status": "canceled",
                  "cancel_at_period_end": true
                },
                "entitlement": { "entitled": false }
              }
            }
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.fetchSubscription(token: "token-1")

        XCTAssertEqual(snapshot.planCode, "typeflux_cloud_monthly")
        XCTAssertEqual(snapshot.status, "canceled")
        XCTAssertTrue(snapshot.cancelAtPeriodEnd)
        XCTAssertFalse(snapshot.entitled)
        XCTAssertFalse(snapshot.billingEnabled)
        XCTAssertFalse(snapshot.shouldShowSubscriptionDetails)
        XCTAssertTrue(snapshot.treatsCreditsAsFreeAllowance)
    }

    func testSubscriptionDecodingInfersEntitlementFromActiveNonFractionalPeriodEnd() throws {
        let json = """
        {
          "plan_code": "typeflux_cloud_monthly",
          "status": "active",
          "current_period_end": "2999-06-01T00:00:00Z"
        }
        """

        let snapshot = try JSONDecoder().decode(BillingSubscriptionSnapshot.self, from: Data(json.utf8))

        XCTAssertTrue(snapshot.entitled)
    }

    func testFetchSubscriptionDecodesFreePlanAsActiveButNotPaid() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            let body = """
            {
              "code": "OK",
              "data": {
                "active": true,
                "paid": false,
                "status": "free",
                "plan_code": "free",
                "plan_name": "Free",
                "current_period_start": "2026-05-12T00:00:00Z",
                "current_period_end": "2026-06-12T00:00:00Z",
                "cancel_at_period_end": false,
                "period_source": "free"
              }
            }
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.fetchSubscription(token: "token-1")

        XCTAssertEqual(snapshot.planCode, "free")
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.status, "free")
        XCTAssertTrue(snapshot.active)
        XCTAssertTrue(snapshot.entitled)
        XCTAssertFalse(snapshot.paid)
        XCTAssertTrue(snapshot.hasSubscription)
        XCTAssertFalse(snapshot.hasPaidSubscription)
        XCTAssertTrue(snapshot.isFreePlan)
    }
}

extension BillingAPIServiceTests {
    func testSyncSubscriptionPostsAuthenticatedEmptyJSONAndUpdatesSnapshot() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/billing/subscription/sync")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
            let body = """
            {
              "code": "OK",
              "data": {
                "billing_enabled": true,
                "plan_code": "pro",
                "status": "active",
                "active": true,
                "paid": true,
                "entitled": true
              }
            }
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.syncSubscription(token: "token-1")

        XCTAssertEqual(snapshot.planCode, "pro")
        XCTAssertTrue(snapshot.hasPaidSubscription)
    }

    func testSyncSubscriptionSurfacesRateLimitWithRetryAfterSeconds() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "37"]
            )!
            return (Data("not required for rate limits".utf8), response)
        }
        let service = makeService(session: session)

        do {
            _ = try await service.syncSubscription(token: "token-1")
            XCTFail("Expected rate limit error")
        } catch let error as BillingSubscriptionSyncError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 37))
            XCTAssertTrue(error.localizedDescription.contains("37"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSyncSubscriptionUsesGenericRateLimitMessageWithoutRetryAfter() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            (Data(), Self.httpResponse(url: request.url!, status: 429))
        }
        let service = makeService(session: session)

        do {
            _ = try await service.syncSubscription(token: "token-1")
            XCTFail("Expected rate limit error")
        } catch let error as BillingSubscriptionSyncError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: nil))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryAfterParsesHTTPDateAndClampsExpiredValues() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let futureResponse = HTTPURLResponse(
            url: baseURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Fri, 15 Jan 2027 08:01:00 GMT"]
        )!
        let expiredResponse = HTTPURLResponse(
            url: baseURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Fri, 15 Jan 2021 08:00:00 GMT"]
        )!

        XCTAssertEqual(BillingAPIService.retryAfterSeconds(from: futureResponse, now: now), 60)
        XCTAssertEqual(BillingAPIService.retryAfterSeconds(from: expiredResponse, now: now), 0)
    }

    func testSyncSubscriptionPreservesStandardServerErrors() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            let body = #"{"code":"BILLING_NOT_CONFIGURED","message":"billing unavailable"}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 400))
        }
        let service = makeService(session: session)

        do {
            _ = try await service.syncSubscription(token: "token-1")
            XCTFail("Expected server error")
        } catch let error as AuthError {
            XCTAssertEqual(error.authErrorCode, "BILLING_NOT_CONFIGURED")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateCheckoutSessionPostsPlanCodeAndDecodesURL() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/billing/checkout-session")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            XCTAssertEqual(json["plan_code"] as? String, "pro")
            let body = """
            {"code": "OK", "data": {"session_id": "cs_test_1", "url": "https://checkout.stripe.com/cs_test_1"}}
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let sessionResponse = try await service.createCheckoutSession(
            token: "token-1",
            planCode: BillingPlan.defaultPlanCode
        )

        XCTAssertEqual(sessionResponse.sessionID, "cs_test_1")
        XCTAssertEqual(sessionResponse.url.absoluteString, "https://checkout.stripe.com/cs_test_1")
    }

    func testCreatePortalSessionPostsToPortalEndpoint() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/billing/portal-session")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = """
            {"code": "OK", "data": {"url": "https://billing.stripe.com/session/test"}}
            """
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let portal = try await service.createPortalSession(token: "token-1")

        XCTAssertEqual(portal.url.absoluteString, "https://billing.stripe.com/session/test")
    }

    func testRequestBillingPageTokenPostsAuthenticatedEmptyJSONAndDecodesToken() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/billing/page-token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
            let body = #"{"code":"OK","data":{"token":"billing.jwt.token","plans_url":"https://billing.example/plans#t=billing.jwt.token"}}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let response = try await service.requestBillingPageToken(token: "token-1")

        XCTAssertEqual(response.token, "billing.jwt.token")
        XCTAssertEqual(response.plansURL.absoluteString, "https://billing.example/plans#t=billing.jwt.token")
    }

    func testRequestBillingPageTokenSurfacesServerError() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            let body = #"{"code":"BILLING_NOT_CONFIGURED","message":"missing secret"}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 400))
        }
        let service = makeService(session: session)

        do {
            _ = try await service.requestBillingPageToken(token: "token-1")
            XCTFail("Expected billing configuration error")
        } catch let error as AuthError {
            XCTAssertEqual(error.authErrorCode, "BILLING_NOT_CONFIGURED")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchSubscriptionRetriesTransientGatewayFailure() async throws {
        let session = BillingStubSession()
        await session.setHandler { request in
            if await session.requestCount == 1 {
                return (Data("bad gateway".utf8), Self.httpResponse(url: request.url!, status: 502))
            }
            let body = #"{"code":"OK","data":{"billing_enabled":true,"plan_code":"free","status":"free","active":true,"paid":false}}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 200))
        }
        let service = makeService(session: session)

        let snapshot = try await service.fetchSubscription(token: "token-1")

        XCTAssertEqual(snapshot.planCode, "free")
        let requestCount = await session.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testFetchSubscriptionReturnsFriendlyErrorAfterGatewayRetriesAreExhausted() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            (Data("bad gateway".utf8), Self.httpResponse(url: request.url!, status: 502))
        }
        let service = makeService(session: session)

        do {
            _ = try await service.fetchSubscription(token: "token-1")
            XCTFail("Expected service unavailable error")
        } catch let error as AuthError {
            XCTAssertEqual(error.authErrorCode, "BILLING_SERVICE_UNAVAILABLE")
            XCTAssertFalse(error.localizedDescription.contains("502"))
            XCTAssertFalse(error.localizedDescription.contains("api.example"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await session.requestCount
        XCTAssertEqual(requestCount, 4)
    }

    func testFetchSubscriptionDoesNotRetryUnauthorizedResponse() async {
        let session = BillingStubSession()
        await session.setHandler { request in
            let body = #"{"code":"AUTH_REFRESH_TOKEN_INVALID","message":"expired"}"#
            return (Data(body.utf8), Self.httpResponse(url: request.url!, status: 401))
        }
        let service = makeService(session: session)

        do {
            _ = try await service.fetchSubscription(token: "token-1")
            XCTFail("Expected unauthorized error")
        } catch is AuthError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await session.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    private func makeService(session: BillingStubSession) -> BillingAPIService {
        let selector = CloudEndpointSelector(baseURLs: [baseURL], prober: BillingNoOpProber())
        return BillingAPIService(
            executor: CloudRequestExecutor(selector: selector, session: session),
            retrySleep: { _ in }
        )
    }

    private static func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private actor BillingStubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handler: Handler?
    private(set) var requestCount = 0

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        guard let handler else {
            throw URLError(.badServerResponse)
        }
        return try await handler(request)
    }
}

private struct BillingNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}
