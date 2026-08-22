@testable import Typeflux
import XCTest

final class TypefluxCloudServerErrorMessageTests: XCTestCase {
    func testKnownCodeUsesLocalizedMessageInsteadOfServerMessage() {
        withEnglishLocalization {
            let message = TypefluxCloudServerErrorMessage.userMessage(
                code: "AUTH_INVALID_CREDENTIALS",
                message: "raw backend message",
                fallback: "fallback"
            )

            XCTAssertEqual(message, "The email or password is incorrect.")
        }
    }

    func testCodeNormalizationAcceptsHyphenatedLowercaseValues() {
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.localizationKey(for: "auth-invalid-credentials"),
            "cloud.error.authInvalidCredentials"
        )
    }

    func testCodeFamilyFallbackHandlesProviderSpecificQuotaCodes() {
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.localizationKey(for: "asr_daily_quota_exceeded"),
            "cloud.error.quotaExceeded"
        )
    }

    func testExistingSubscriptionCodeUsesLocalizedBillingMessage() {
        withEnglishLocalization {
            let message = TypefluxCloudServerErrorMessage.userMessage(
                code: "BILLING_SUBSCRIPTION_EXISTS",
                message: "raw backend message",
                fallback: "fallback"
            )

            XCTAssertEqual(
                message,
                "You already have a subscription. Open billing management to change or resume it."
            )
        }
    }

    func testBillingAvailabilityCodesUseActionableLocalizedMessages() {
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.localizationKey(for: "BILLING_CONNECTION_UNAVAILABLE"),
            "cloud.error.billingConnectionUnavailable"
        )
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.localizationKey(for: "BILLING_SERVICE_UNAVAILABLE"),
            "cloud.error.billingServiceUnavailable"
        )
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.localizationKey(for: "BILLING_NOT_CONFIGURED"),
            "cloud.error.billingServiceUnavailable"
        )
    }

    func testBillingErrorParsesSubscriptionRequiredHTTPBody() {
        let body = Data(#"{"code":"SUBSCRIPTION_REQUIRED","message":"active subscription required"}"#.utf8)
        let error = TypefluxCloudBillingError.fromHTTPStatus(402, bodyData: body)

        XCTAssertEqual(error?.reason, .subscriptionRequired)
    }

    func testBillingErrorParsesFailingHTTP402ResponseFromNSError() throws {
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://api.example/asr")),
            statusCode: 402,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: URLError.badServerResponse.rawValue,
            userInfo: ["NSErrorFailingURLResponseKey": response]
        )

        XCTAssertEqual(TypefluxCloudBillingError.fromError(error)?.reason, .subscriptionRequired)
    }

    func testBillingErrorParsesQuotaAndPaymentCodes() {
        XCTAssertEqual(
            TypefluxCloudBillingError.fromServerCode("INSUFFICIENT_CREDITS", message: nil)?.reason,
            .quotaExceeded
        )
        XCTAssertEqual(
            TypefluxCloudBillingError.fromServerCode("PAYMENT_REQUIRED", message: nil)?.reason,
            .subscriptionRequired
        )
    }

    func testBillingErrorPrimaryActionMatchesReason() {
        withEnglishLocalization {
            let subscriptionRequired = TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nil)
            let quotaExceeded = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)

            XCTAssertEqual(
                subscriptionRequired.title(hasPaidSubscription: false),
                "Typeflux Cloud needs a subscription"
            )
            XCTAssertEqual(quotaExceeded.title(hasPaidSubscription: false), "Typeflux Cloud needs a subscription")
            XCTAssertEqual(quotaExceeded.title(hasPaidSubscription: true), "Typeflux Cloud credits used up")
            XCTAssertEqual(
                subscriptionRequired.primaryActionTitle,
                "Subscribe"
            )
            XCTAssertEqual(
                quotaExceeded.primaryActionTitle,
                "Subscribe"
            )
            XCTAssertEqual(
                quotaExceeded.primaryActionTitle(hasPaidSubscription: true),
                "Open Account"
            )
        }
    }

    func testBillingErrorDoesNotSuggestSubscriptionWhenBillingIsDisabled() {
        withEnglishLocalization {
            let error = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)

            XCTAssertEqual(
                error.title(hasPaidSubscription: false, billingEnabled: false),
                "Free Cloud credits used up"
            )
            XCTAssertEqual(
                error.primaryActionTitle(hasPaidSubscription: false, billingEnabled: false),
                "Open Account"
            )
            XCTAssertFalse(
                error.message(hasPaidSubscription: false, billingEnabled: false).localizedCaseInsensitiveContains(
                    "subscribe"
                )
            )
        }
    }

    func testBillingErrorParsesCreditBalanceExhaustedMessage() {
        let message = "request failed: credit_balance_exhausted"

        XCTAssertEqual(TypefluxCloudBillingError.fromMessage(message)?.reason, .quotaExceeded)
    }

    func testUnknownCodeUsesTrimmedServerMessageThenFallback() {
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.userMessage(
                code: "CUSTOM_ERROR",
                message: "  Custom failure  ",
                fallback: "fallback"
            ),
            "Custom failure"
        )
        XCTAssertEqual(
            TypefluxCloudServerErrorMessage.userMessage(code: "CUSTOM_ERROR", message: "  ", fallback: "fallback"),
            "fallback"
        )
    }

    private func withEnglishLocalization(_ body: () -> Void) {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        body()
    }
}
