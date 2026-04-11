@testable import Typeflux
import XCTest

final class AuthModelsTests: XCTestCase {
    // MARK: - EnterEmailRequest

    func testEnterEmailRequestEncoding() throws {
        let request = EnterEmailRequest(email: "test@example.com")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["email"] as? String, "test@example.com")
    }

    // MARK: - EnterEmailResponse

    func testEnterEmailResponseDecodingExistingUser() throws {
        let json = """
        {"exists": true, "next": "login", "tip": "account exists"}
        """
        let response = try JSONDecoder().decode(EnterEmailResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.exists)
        XCTAssertEqual(response.next, "login")
        XCTAssertEqual(response.tip, "account exists")
    }

    func testEnterEmailResponseDecodingNewUser() throws {
        let json = """
        {"exists": false, "next": "register"}
        """
        let response = try JSONDecoder().decode(EnterEmailResponse.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(response.exists)
        XCTAssertEqual(response.next, "register")
        XCTAssertNil(response.tip)
    }

    // MARK: - RegisterRequest

    func testRegisterRequestEncoding() throws {
        let request = RegisterRequest(email: "user@test.com", password: "Pass1234", name: "John")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["email"] as? String, "user@test.com")
        XCTAssertEqual(dict?["password"] as? String, "Pass1234")
        XCTAssertEqual(dict?["name"] as? String, "John")
    }

    func testRegisterRequestEncodingNilName() throws {
        let request = RegisterRequest(email: "user@test.com", password: "Pass1234", name: nil)
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["email"] as? String, "user@test.com")
        XCTAssertNil(dict?["name"] as? String)
    }

    // MARK: - RegisterResponse

    func testRegisterResponseDecoding() throws {
        let json = """
        {"sent": true}
        """
        let response = try JSONDecoder().decode(RegisterResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.sent)
    }

    // MARK: - ActivateRequest

    func testActivateRequestEncoding() throws {
        let request = ActivateRequest(email: "user@test.com", code: "ABC12345")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["email"] as? String, "user@test.com")
        XCTAssertEqual(dict?["code"] as? String, "ABC12345")
    }

    // MARK: - ActivateResponse

    func testActivateResponseDecoding() throws {
        let json = """
        {"activated": true}
        """
        let response = try JSONDecoder().decode(ActivateResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.activated)
    }

    // MARK: - LoginRequest

    func testLoginRequestEncoding() throws {
        let request = LoginRequest(email: "user@test.com", password: "Pass1234")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["email"] as? String, "user@test.com")
        XCTAssertEqual(dict?["password"] as? String, "Pass1234")
    }

    // MARK: - LoginResponse

    func testLoginResponseDecoding() throws {
        let json = """
        {"access_token": "jwt.token.here", "expires_at": 1712867400}
        """
        let response = try JSONDecoder().decode(LoginResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.accessToken, "jwt.token.here")
        XCTAssertEqual(response.expiresAt, 1712867400)
        XCTAssertNil(response.refreshToken)
    }

    func testLoginResponseDecodingWithRefreshToken() throws {
        let json = """
        {"access_token": "jwt.token.here", "expires_at": 1712867400, "refresh_token": "rt_abc123"}
        """
        let response = try JSONDecoder().decode(LoginResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.accessToken, "jwt.token.here")
        XCTAssertEqual(response.expiresAt, 1712867400)
        XCTAssertEqual(response.refreshToken, "rt_abc123")
    }

    // MARK: - RefreshRequest

    func testRefreshRequestEncoding() throws {
        let request = RefreshRequest(refreshToken: "rt_mytoken123")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["refresh_token"] as? String, "rt_mytoken123")
        XCTAssertNil(dict?["refreshToken"])  // must use snake_case key
    }

    // MARK: - LogoutRequest

    func testLogoutRequestEncoding() throws {
        let request = LogoutRequest(refreshToken: "rt_logoutme")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["refresh_token"] as? String, "rt_logoutme")
        XCTAssertNil(dict?["refreshToken"])  // must use snake_case key
    }

    // MARK: - LogoutResponse

    func testLogoutResponseDecoding() throws {
        let json = """
        {"logged_out": true}
        """
        let response = try JSONDecoder().decode(LogoutResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.loggedOut)
    }

    func testLogoutResponseDecodingFalse() throws {
        let json = """
        {"logged_out": false}
        """
        let response = try JSONDecoder().decode(LogoutResponse.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(response.loggedOut)
    }

    // MARK: - UserProfile

    func testUserProfileDecoding() throws {
        let json = """
        {
            "id": "user-uuid-123",
            "email": "user@test.com",
            "name": "John Doe",
            "status": 1,
            "provider": "password",
            "created_at": "2024-04-09T12:00:00Z",
            "updated_at": "2024-04-09T12:00:00Z"
        }
        """
        let profile = try JSONDecoder().decode(UserProfile.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(profile.id, "user-uuid-123")
        XCTAssertEqual(profile.email, "user@test.com")
        XCTAssertEqual(profile.name, "John Doe")
        XCTAssertEqual(profile.status, 1)
        XCTAssertEqual(profile.provider, "password")
        XCTAssertEqual(profile.createdAt, "2024-04-09T12:00:00Z")
        XCTAssertEqual(profile.resolvedDisplayName, "John Doe")
    }

    func testUserProfileDecodingWithoutNameFallsBackToEmail() throws {
        let json = """
        {
            "id": "user-uuid-123",
            "email": "user@test.com",
            "status": 1,
            "provider": "password",
            "created_at": "2024-04-09T12:00:00Z",
            "updated_at": "2024-04-09T12:00:00Z"
        }
        """
        let profile = try JSONDecoder().decode(UserProfile.self, from: json.data(using: .utf8)!)
        XCTAssertNil(profile.name)
        XCTAssertEqual(profile.resolvedDisplayName, "user@test.com")
    }

    func testUserProfileRoundTrip() throws {
        let profile = UserProfile(
            id: "test-id",
            email: "a@b.com",
            name: "Test",
            status: 1,
            provider: "google",
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    // MARK: - APIResponse

    func testAPIResponseWithData() throws {
        let json = """
        {"code": "OK", "data": {"access_token": "tok", "expires_at": 12345}}
        """
        let envelope = try JSONDecoder().decode(
            APIResponse<LoginResponse>.self,
            from: json.data(using: .utf8)!,
        )
        XCTAssertEqual(envelope.code, "OK")
        XCTAssertNil(envelope.message)
        XCTAssertEqual(envelope.data?.accessToken, "tok")
    }

    func testAPIResponseWithDataAndRefreshToken() throws {
        let json = """
        {"code": "OK", "data": {"access_token": "tok", "expires_at": 12345, "refresh_token": "rt_xyz"}}
        """
        let envelope = try JSONDecoder().decode(
            APIResponse<LoginResponse>.self,
            from: json.data(using: .utf8)!,
        )
        XCTAssertEqual(envelope.data?.refreshToken, "rt_xyz")
    }

    func testAPIResponseWithError() throws {
        let json = """
        {"code": "AUTH_INVALID_CREDENTIALS", "message": "wrong password"}
        """
        let envelope = try JSONDecoder().decode(
            APIResponse<LoginResponse>.self,
            from: json.data(using: .utf8)!,
        )
        XCTAssertEqual(envelope.code, "AUTH_INVALID_CREDENTIALS")
        XCTAssertEqual(envelope.message, "wrong password")
        XCTAssertNil(envelope.data)
    }

    // MARK: - AuthError

    func testAuthErrorDescriptions() {
        let networkError = AuthError.networkError(URLError(.notConnectedToInternet))
        XCTAssertNotNil(networkError.errorDescription)

        let serverError = AuthError.serverError(code: "AUTH_USER_EXISTS", message: "User exists")
        XCTAssertEqual(serverError.errorDescription, "User exists")
        XCTAssertEqual(serverError.authErrorCode, "AUTH_USER_EXISTS")

        let invalidResponse = AuthError.invalidResponse
        XCTAssertNotNil(invalidResponse.errorDescription)
        XCTAssertNil(invalidResponse.authErrorCode)

        let unauthorized = AuthError.unauthorized
        XCTAssertNotNil(unauthorized.errorDescription)
        XCTAssertNil(unauthorized.authErrorCode)
    }

    func testAuthErrorServerErrorWithNilMessage() {
        let error = AuthError.serverError(code: "INTERNAL", message: nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.authErrorCode, "INTERNAL")
    }

    func testAuthErrorRefreshTokenInvalidCode() {
        let error = AuthError.serverError(code: "AUTH_REFRESH_TOKEN_INVALID", message: "invalid or expired refresh token")
        XCTAssertEqual(error.authErrorCode, "AUTH_REFRESH_TOKEN_INVALID")
        XCTAssertEqual(error.errorDescription, "invalid or expired refresh token")
    }

    func testAuthErrorRefreshTokenReusedCode() {
        let error = AuthError.serverError(code: "AUTH_REFRESH_TOKEN_REUSED", message: "refresh token already used")
        XCTAssertEqual(error.authErrorCode, "AUTH_REFRESH_TOKEN_REUSED")
        XCTAssertEqual(error.errorDescription, "refresh token already used")
    }
}
