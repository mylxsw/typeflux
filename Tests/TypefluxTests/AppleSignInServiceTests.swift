import AuthenticationServices
import XCTest
@testable import Typeflux

@MainActor
final class AppleSignInServiceTests: XCTestCase {
    func testConfigurationIssueDescriptionWhenEntitlementMissing() {
        let description = AppleSignInService.configurationIssueDescription(
            for: .init(
                bundleIdentifier: "dev.typeflux",
                teamIdentifier: "N95437SZ2A",
                hasAppleSignInEntitlement: false
            )
        )

        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("not enabled in this dev build") == true)
        XCTAssertTrue(description?.contains("TYPEFLUX_DEV_PROVISIONING_PROFILE") == true)
    }

    func testConfigurationIssueDescriptionWhenBuildIsAdHocSigned() {
        let description = AppleSignInService.configurationIssueDescription(
            for: .init(
                bundleIdentifier: "dev.typeflux",
                teamIdentifier: nil,
                hasAppleSignInEntitlement: true
            )
        )

        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Apple Development signature") == true)
        XCTAssertTrue(description?.contains("embedded macOS provisioning profile") == true)
    }

    func testMapSystemErrorPromotesUnknownAuthorizationFailureToConfigurationIssue() {
        let originalError = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.unknown.rawValue
        )

        let mappedError = AppleSignInService.mapSystemError(
            originalError,
            runtimeConfiguration: .init(
                bundleIdentifier: "dev.typeflux",
                teamIdentifier: "N95437SZ2A",
                hasAppleSignInEntitlement: false
            )
        )

        guard case .configurationIssue(let description) = mappedError as? AppleSignInError else {
            return XCTFail("Expected a configuration issue error.")
        }
        XCTAssertTrue(description.contains("TYPEFLUX_DEV_PROVISIONING_PROFILE"))
    }

    func testMapSystemErrorLeavesNonConfigurationFailuresUntouched() {
        let originalError = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )

        let mappedError = AppleSignInService.mapSystemError(
            originalError,
            runtimeConfiguration: .init(
                bundleIdentifier: "dev.typeflux",
                teamIdentifier: "N95437SZ2A",
                hasAppleSignInEntitlement: true
            )
        ) as NSError

        XCTAssertEqual(mappedError.domain, ASAuthorizationError.errorDomain)
        XCTAssertEqual(mappedError.code, ASAuthorizationError.canceled.rawValue)
    }
}
