import XCTest
@testable import Typeflux

final class GoogleCloudSpeechOAuthTests: XCTestCase {
    override func tearDown() {
        GoogleCloudSpeechOAuthTokenStore.clear()
        super.tearDown()
    }

    func testStoredAuthorizationAvailabilityIsFalseWhenStoreIsEmpty() {
        GoogleCloudSpeechOAuthTokenStore.clear()

        XCTAssertFalse(GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable())
    }

    func testStoredAuthorizationAvailabilityIsTrueForValidAccessToken() {
        GoogleCloudSpeechOAuthTokenStore.save(
            GoogleCloudSpeechOAuthToken(
                accessToken: "ya29.valid-token",
                refreshToken: nil,
                expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            )
        )

        XCTAssertTrue(GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable())
    }

    func testStoredAuthorizationAvailabilityIsTrueForRefreshableExpiredToken() {
        GoogleCloudSpeechOAuthTokenStore.save(
            GoogleCloudSpeechOAuthToken(
                accessToken: "",
                refreshToken: "refresh-token",
                expiresAt: Int(Date().timeIntervalSince1970) - 60,
            )
        )

        XCTAssertTrue(GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable())
    }

    func testResolveCredentialPrefersManualCredential() async throws {
        GoogleCloudSpeechOAuthTokenStore.save(
            GoogleCloudSpeechOAuthToken(
                accessToken: "ya29.stored-token",
                refreshToken: nil,
                expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            )
        )

        let credential = try await GoogleCloudSpeechCredentialResolver.resolveCredential(
            manualCredential: "AIzaManualKey",
        )

        XCTAssertEqual(credential, "AIzaManualKey")
    }

    func testResolveCredentialUsesStoredAccessTokenWhenManualCredentialIsEmpty() async throws {
        GoogleCloudSpeechOAuthTokenStore.save(
            GoogleCloudSpeechOAuthToken(
                accessToken: "ya29.stored-token",
                refreshToken: "refresh-token",
                expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            )
        )

        let credential = try await GoogleCloudSpeechCredentialResolver.resolveCredential(
            manualCredential: " ",
        )

        XCTAssertEqual(credential, "ya29.stored-token")
    }

    func testResolveCredentialRefreshesStoredTokenWhenAccessTokenIsExpiringSoon() async throws {
        let storedToken = GoogleCloudSpeechOAuthToken(
            accessToken: "ya29.expiring-token",
            refreshToken: "refresh-token",
            expiresAt: Int(Date().timeIntervalSince1970) + 60,
        )
        let refreshedToken = GoogleCloudSpeechOAuthToken(
            accessToken: "ya29.refreshed-token",
            refreshToken: "refresh-token-updated",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
        )
        var savedToken: GoogleCloudSpeechOAuthToken?
        var capturedRefreshToken: String?
        var capturedClientID: String?
        var capturedClientSecret: String?

        let credential = try await GoogleCloudSpeechCredentialResolver.resolveCredential(
            manualCredential: "",
            clientID: "client-id",
            clientSecret: " client-secret ",
            tokenLoader: { storedToken },
            tokenSaver: { savedToken = $0 },
            tokenRefresher: { refreshToken, clientID, clientSecret in
                capturedRefreshToken = refreshToken
                capturedClientID = clientID
                capturedClientSecret = clientSecret
                return refreshedToken
            }
        )

        XCTAssertEqual(credential, refreshedToken.accessToken)
        XCTAssertEqual(savedToken, refreshedToken)
        XCTAssertEqual(capturedRefreshToken, "refresh-token")
        XCTAssertEqual(capturedClientID, "client-id")
        XCTAssertEqual(capturedClientSecret, "client-secret")
    }

    func testResolveCredentialThrowsWhenStoredTokenNeedsRefreshButHasNoRefreshToken() async {
        let storedToken = GoogleCloudSpeechOAuthToken(
            accessToken: "ya29.expiring-token",
            refreshToken: " ",
            expiresAt: Int(Date().timeIntervalSince1970) + 60,
        )

        await XCTAssertThrowsErrorAsync(
            try await GoogleCloudSpeechCredentialResolver.resolveCredential(
                manualCredential: "",
                tokenLoader: { storedToken },
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                GoogleCloudSpeechError.missingAPIKey.localizedDescription,
            )
        }
    }

    func testResolveCredentialThrowsWhenNoManualCredentialOrStoredAuthorizationExists() async {
        GoogleCloudSpeechOAuthTokenStore.clear()

        await XCTAssertThrowsErrorAsync(
            try await GoogleCloudSpeechCredentialResolver.resolveCredential(
                manualCredential: "",
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                GoogleCloudSpeechError.missingAPIKey.localizedDescription,
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error")
    } catch {
        errorHandler(error)
    }
}
