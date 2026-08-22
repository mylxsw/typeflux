@testable import Typeflux
import XCTest

@MainActor
final class AccountBillingFlowTests: XCTestCase {
    func testBillingPlansURLPlacesEncodedTokenInFragment() throws {
        let url = try AccountBillingFlow.billingPlansURL(token: "header.payload+/signature=")

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "typeflux.app")
        XCTAssertEqual(url.path, "/billing/plans")

        let fragment = try XCTUnwrap(url.fragment)
        let fragmentComponents = try XCTUnwrap(URLComponents(string: "?\(fragment)"))
        XCTAssertEqual(fragmentComponents.queryItems, [URLQueryItem(name: "t", value: "header.payload+/signature=")])
        XCTAssertNil(url.query)
    }

    func testSubscribeDestinationRequestsPageTokenWithoutCreatingPortal() async throws {
        var tokenRequests = 0
        var portalRequests = 0

        let url = try await AccountBillingFlow.destination(
            for: .subscribe,
            requestBillingPageToken: {
                tokenRequests += 1
                return "billing.jwt.token"
            },
            createPortalSession: {
                portalRequests += 1
                return URL(string: "https://billing.stripe.com/portal")!
            }
        )

        XCTAssertEqual(url.absoluteString, "https://typeflux.app/billing/plans#t=billing.jwt.token")
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(portalRequests, 0)
    }

    func testManageBillingDestinationCreatesPortalWithoutRequestingPageToken() async throws {
        var tokenRequests = 0
        var portalRequests = 0

        let url = try await AccountBillingFlow.destination(
            for: .manageBilling,
            requestBillingPageToken: {
                tokenRequests += 1
                return "billing.jwt.token"
            },
            createPortalSession: {
                portalRequests += 1
                return URL(string: "https://billing.stripe.com/portal")!
            }
        )

        XCTAssertEqual(url.absoluteString, "https://billing.stripe.com/portal")
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertEqual(portalRequests, 1)
    }

    func testSubscribeDestinationPropagatesPageTokenFailure() async {
        var portalRequests = 0

        do {
            _ = try await AccountBillingFlow.destination(
                for: .subscribe,
                requestBillingPageToken: {
                    throw AuthError.serverError(code: "BILLING_NOT_CONFIGURED", message: nil)
                },
                createPortalSession: {
                    portalRequests += 1
                    return URL(string: "https://billing.stripe.com/portal")!
                }
            )
            XCTFail("Expected page token request to fail")
        } catch let error as AuthError {
            XCTAssertEqual(error.authErrorCode, "BILLING_NOT_CONFIGURED")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(portalRequests, 0)
    }

    func testBillingPlansURLRejectsEmptyTokenWithLocalizedError() {
        XCTAssertThrowsError(try AccountBillingFlow.billingPlansURL(token: "   \n")) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertNotEqual(error.localizedDescription, "cloud.error.billingPageUnavailable")
        }
    }
}
