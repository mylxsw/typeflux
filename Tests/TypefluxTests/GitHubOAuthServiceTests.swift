import XCTest
@testable import Typeflux

@MainActor
final class GitHubOAuthServiceTests: XCTestCase {
    func testMakeAuthorizationURLIncludesPKCEParameters() throws {
        let url = GitHubOAuthService.makeAuthorizationURL(
            clientID: "client-id",
            state: "state-123",
            codeChallenge: "challenge-456"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        XCTAssertEqual(queryItems.first(where: { $0.name == "client_id" })?.value, "client-id")
        XCTAssertEqual(queryItems.first(where: { $0.name == "redirect_uri" })?.value, "ai.gulu.app.typeflux://oauth/github")
        XCTAssertEqual(queryItems.first(where: { $0.name == "scope" })?.value, "read:user user:email")
        XCTAssertEqual(queryItems.first(where: { $0.name == "state" })?.value, "state-123")
        XCTAssertEqual(queryItems.first(where: { $0.name == "code_challenge" })?.value, "challenge-456")
        XCTAssertEqual(queryItems.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
    }
}
