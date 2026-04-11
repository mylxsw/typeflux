import XCTest
@testable import Typeflux

@MainActor
final class AuthStateTests: XCTestCase {
    func testRestoreSessionRefreshesProfileAndPersistsUser() async {
        let fetchExpectation = expectation(description: "fetch profile")
        let storedToken = validStoredToken()
        var savedProfile: UserProfile?
        let profile = makeProfile(email: "refresh@test.com")
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { savedProfile },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { savedProfile = $0 },
            clearStoredSession: {},
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                return profile
            },
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(state.userProfile, profile)
        XCTAssertEqual(savedProfile, profile)
    }

    func testRestoreSessionLogsOutWhenProfileRefreshUnauthorized() async {
        let fetchExpectation = expectation(description: "fetch profile")
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        var clearedSession = false
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
                storedToken = nil
            },
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                throw AuthError.unauthorized
            },
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertTrue(clearedSession)
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertNil(state.userProfile)
    }

    func testRestoreSessionKeepsSessionOnNetworkFailure() async {
        let fetchExpectation = expectation(description: "fetch profile")
        let storedToken = validStoredToken()
        var clearedSession = false
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
            },
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                throw AuthError.networkError(NSError(domain: "test", code: -1))
            },
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertFalse(clearedSession)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertNil(state.userProfile)
    }

    private func makeProfile(email: String) -> UserProfile {
        UserProfile(
            id: UUID().uuidString,
            email: email,
            name: "Test User",
            status: 1,
            provider: "password",
            createdAt: "2024-04-09T12:00:00Z",
            updatedAt: "2024-04-09T12:00:00Z",
        )
    }

    private func validStoredToken() -> (token: String, expiresAt: Int) {
        ("valid-token", Int(Date().timeIntervalSince1970) + 3600)
    }

    private func waitForRefreshCompletion(_ state: AuthState) async {
        while state.isLoading {
            await Task.yield()
        }
        await Task.yield()
    }
}
