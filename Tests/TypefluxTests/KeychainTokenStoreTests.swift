@testable import Typeflux
import XCTest

final class KeychainTokenStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainTokenStore.clearAll()
    }

    override func tearDown() {
        KeychainTokenStore.clearAll()
        super.tearDown()
    }

    // MARK: - Token

    func testSaveAndLoadToken() {
        KeychainTokenStore.saveToken("test-token-123", expiresAt: 9_999_999_999)
        let loaded = KeychainTokenStore.loadToken()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.token, "test-token-123")
        XCTAssertEqual(loaded?.expiresAt, 9_999_999_999)
    }

    func testLoadTokenReturnsNilWhenEmpty() {
        let loaded = KeychainTokenStore.loadToken()
        XCTAssertNil(loaded)
    }

    func testDeleteToken() {
        KeychainTokenStore.saveToken("to-delete", expiresAt: 9_999_999_999)
        KeychainTokenStore.deleteToken()
        XCTAssertNil(KeychainTokenStore.loadToken())
    }

    func testIsTokenValidWithFutureExpiry() {
        let futureExpiry = Int(Date().timeIntervalSince1970) + 3600
        KeychainTokenStore.saveToken("valid-token", expiresAt: futureExpiry)
        XCTAssertTrue(KeychainTokenStore.isTokenValid)
    }

    func testIsTokenValidWithPastExpiry() {
        let pastExpiry = Int(Date().timeIntervalSince1970) - 3600
        KeychainTokenStore.saveToken("expired-token", expiresAt: pastExpiry)
        XCTAssertFalse(KeychainTokenStore.isTokenValid)
    }

    func testIsTokenValidWhenNoToken() {
        XCTAssertFalse(KeychainTokenStore.isTokenValid)
    }

    func testTokenOverwrite() {
        KeychainTokenStore.saveToken("first", expiresAt: 111)
        KeychainTokenStore.saveToken("second", expiresAt: 222)
        let loaded = KeychainTokenStore.loadToken()
        XCTAssertEqual(loaded?.token, "second")
        XCTAssertEqual(loaded?.expiresAt, 222)
    }

    // MARK: - Refresh Token

    func testSaveTokenWithRefreshToken() {
        KeychainTokenStore.saveToken("access-tok", expiresAt: 9_999_999_999, refreshToken: "rt_refresh123")
        let loaded = KeychainTokenStore.loadToken()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.token, "access-tok")
        let refresh = KeychainTokenStore.loadRefreshToken()
        XCTAssertEqual(refresh, "rt_refresh123")
    }

    func testSaveTokenWithoutRefreshTokenNilByDefault() {
        KeychainTokenStore.saveToken("access-only", expiresAt: 9_999_999_999)
        let refresh = KeychainTokenStore.loadRefreshToken()
        XCTAssertNil(refresh)
    }

    func testLoadRefreshTokenReturnsNilWhenNoToken() {
        let refresh = KeychainTokenStore.loadRefreshToken()
        XCTAssertNil(refresh)
    }

    func testRefreshTokenClearedWithDeleteToken() {
        KeychainTokenStore.saveToken("access-tok", expiresAt: 9_999_999_999, refreshToken: "rt_abc")
        KeychainTokenStore.deleteToken()
        XCTAssertNil(KeychainTokenStore.loadRefreshToken())
    }

    func testOverwritePreservesNewRefreshToken() {
        KeychainTokenStore.saveToken("first", expiresAt: 111, refreshToken: "rt_first")
        KeychainTokenStore.saveToken("second", expiresAt: 222, refreshToken: "rt_second")
        XCTAssertEqual(KeychainTokenStore.loadRefreshToken(), "rt_second")
    }

    func testOverwriteWithNilRefreshTokenClearsIt() {
        KeychainTokenStore.saveToken("first", expiresAt: 111, refreshToken: "rt_first")
        KeychainTokenStore.saveToken("second", expiresAt: 222)  // no refreshToken
        XCTAssertNil(KeychainTokenStore.loadRefreshToken())
    }

    // MARK: - isTokenExpiringSoon

    func testIsTokenExpiringSoonWithFarFutureExpiry() {
        // Expires 30 days from now — not expiring soon within 7-day window
        let farExpiry = Int(Date().timeIntervalSince1970) + 30 * 24 * 3600
        KeychainTokenStore.saveToken("tok", expiresAt: farExpiry)
        XCTAssertFalse(KeychainTokenStore.isTokenExpiringSoon())
    }

    func testIsTokenExpiringSoonWithImminent() {
        // Expires in 2 days — within default 7-day window
        let imminentExpiry = Int(Date().timeIntervalSince1970) + 2 * 24 * 3600
        KeychainTokenStore.saveToken("tok", expiresAt: imminentExpiry)
        XCTAssertTrue(KeychainTokenStore.isTokenExpiringSoon())
    }

    func testIsTokenExpiringSoonWithAlreadyExpired() {
        let pastExpiry = Int(Date().timeIntervalSince1970) - 3600
        KeychainTokenStore.saveToken("tok", expiresAt: pastExpiry)
        XCTAssertTrue(KeychainTokenStore.isTokenExpiringSoon())
    }

    func testIsTokenExpiringSoonWhenNoToken() {
        // No token → should be treated as expiring (triggers refresh attempt)
        XCTAssertTrue(KeychainTokenStore.isTokenExpiringSoon())
    }

    func testIsTokenExpiringSoonCustomInterval() {
        // Expires in 3 days; custom interval = 1 day → not expiring soon
        let expiry3d = Int(Date().timeIntervalSince1970) + 3 * 24 * 3600
        KeychainTokenStore.saveToken("tok", expiresAt: expiry3d)
        XCTAssertFalse(KeychainTokenStore.isTokenExpiringSoon(within: 24 * 3600))
    }

    // MARK: - User Profile

    func testSaveAndLoadUserProfile() {
        let profile = UserProfile(
            id: "uid-1",
            email: "user@test.com",
            name: "Test User",
            status: 1,
            provider: "password",
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z"
        )
        KeychainTokenStore.saveUserProfile(profile)
        let loaded = KeychainTokenStore.loadUserProfile()
        XCTAssertEqual(loaded, profile)
    }

    func testLoadUserProfileReturnsNilWhenEmpty() {
        XCTAssertNil(KeychainTokenStore.loadUserProfile())
    }

    func testDeleteUserProfile() {
        let profile = UserProfile(
            id: "uid-2",
            email: "a@b.com",
            name: "A",
            status: 1,
            provider: "google",
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z"
        )
        KeychainTokenStore.saveUserProfile(profile)
        KeychainTokenStore.deleteUserProfile()
        XCTAssertNil(KeychainTokenStore.loadUserProfile())
    }

    // MARK: - Clear All

    func testClearAll() {
        KeychainTokenStore.saveToken("tok", expiresAt: 9_999_999_999, refreshToken: "rt_clear")
        let profile = UserProfile(
            id: "uid-3",
            email: "c@d.com",
            name: "C",
            status: 1,
            provider: "apple",
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z"
        )
        KeychainTokenStore.saveUserProfile(profile)

        KeychainTokenStore.clearAll()

        XCTAssertNil(KeychainTokenStore.loadToken())
        XCTAssertNil(KeychainTokenStore.loadRefreshToken())
        XCTAssertNil(KeychainTokenStore.loadUserProfile())
    }
}
