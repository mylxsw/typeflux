@testable import Typeflux
import XCTest

final class LoginViewPolicyGuardTests: XCTestCase {
    private var originalLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        originalLanguage = AppLocalization.shared.language
    }

    override func tearDown() {
        AppLocalization.shared.setLanguage(originalLanguage)
        originalLanguage = nil
        super.tearDown()
    }

    func testGoogleLoginPreflightBlocksWhenPoliciesNotAccepted() {
        AppLocalization.shared.setLanguage(.english)

        let errorMessage = LoginGooglePreflight.errorMessage(
            for: .enterEmail,
            hasAcceptedPolicies: false
        )

        XCTAssertEqual(
            errorMessage,
            "Please accept the Terms of Service and Privacy Policy first."
        )
    }

    func testGoogleLoginPreflightAllowsAttemptAfterPoliciesAccepted() {
        let errorMessage = LoginGooglePreflight.errorMessage(
            for: .enterEmail,
            hasAcceptedPolicies: true
        )

        XCTAssertNil(errorMessage)
    }

    func testGoogleLoginPreflightDoesNotRequirePoliciesOutsideEntryStep() {
        let errorMessage = LoginGooglePreflight.errorMessage(
            for: .login,
            hasAcceptedPolicies: false
        )

        XCTAssertNil(errorMessage)
    }

    func testGoogleLoginPreflightUsesCurrentLocalization() {
        AppLocalization.shared.setLanguage(.simplifiedChinese)

        let errorMessage = LoginGooglePreflight.errorMessage(
            for: .enterEmail,
            hasAcceptedPolicies: false
        )

        XCTAssertEqual(errorMessage, "请先同意《用户协议》和《隐私政策》。")
    }

    func testAppleLoginPreflightSurfacesUnavailableConfigurationMessage() {
        let errorMessage = LoginApplePreflight.errorMessage(
            availability: .unavailable("Apple Sign In is unavailable in this build.")
        )

        XCTAssertEqual(errorMessage, "Apple Sign In is unavailable in this build.")
    }

    func testAppleLoginPreflightAllowsAttemptWhenAvailabilityIsUnknown() {
        XCTAssertNil(LoginApplePreflight.errorMessage(availability: .unknown))
    }

    func testAppleLoginPreflightAllowsAttemptWhenAvailable() {
        XCTAssertNil(LoginApplePreflight.errorMessage(availability: .available))
    }

    func testSocialLoginLayoutIncludesProvidersInStableOrder() {
        let providers = SocialLoginLayout.enabledProviders(
            googleClientID: "google-client",
            githubClientID: "github-client",
            includeApple: true
        )

        XCTAssertEqual(providers, [.apple, .google, .github])
    }

    func testSocialLoginLayoutOmitsUnavailableProviders() {
        let googleOnly = SocialLoginLayout.enabledProviders(
            googleClientID: "google-client",
            githubClientID: "",
            includeApple: false
        )
        let githubOnly = SocialLoginLayout.enabledProviders(
            googleClientID: "",
            githubClientID: "github-client",
            includeApple: false
        )
        let none = SocialLoginLayout.enabledProviders(
            googleClientID: "",
            githubClientID: "",
            includeApple: false
        )

        XCTAssertEqual(googleOnly, [.google])
        XCTAssertEqual(githubOnly, [.github])
        XCTAssertTrue(none.isEmpty)
    }

    func testSocialLoginLayoutRowsCanKeepThreeProvidersInOneRow() {
        let rows = SocialLoginLayout.rows(
            for: [.apple, .google, .github],
            maxItemsPerRow: 3
        )

        XCTAssertEqual(rows, [[.apple, .google, .github]])
    }

    func testSocialLoginLayoutRowsFallbackToSingleColumnForInvalidItemCount() {
        let rows = SocialLoginLayout.rows(
            for: [.google, .github],
            maxItemsPerRow: 0
        )

        XCTAssertEqual(rows, [[.google], [.github]])
    }
}
