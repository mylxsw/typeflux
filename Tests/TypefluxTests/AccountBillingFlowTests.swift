@testable import Typeflux
import XCTest

@MainActor
final class AccountBillingFlowTests: XCTestCase {
    func testSubscribeDestinationUsesServerPlansURLWithoutCreatingPortal() async throws {
        var tokenRequests = 0
        var portalRequests = 0

        let url = try await AccountBillingFlow.destination(
            for: .subscribe,
            requestBillingPageToken: {
                tokenRequests += 1
                return URL(string: "https://billing.example/custom/plans#t=billing.jwt.token")!
            },
            createPortalSession: {
                portalRequests += 1
                return URL(string: "https://billing.stripe.com/portal")!
            }
        )

        XCTAssertEqual(url.absoluteString, "https://billing.example/custom/plans#t=billing.jwt.token")
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
                return URL(string: "https://billing.example/custom/plans#t=billing.jwt.token")!
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
}
