import Foundation
@testable import TypefluxChat
import XCTest

final class GoogleOAuthTests: XCTestCase {
    private let clientID = "123-ios.apps.googleusercontent.com"
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    func testAuthorizationUsesPKCEAndUniqueAttempts() throws {
        let auth = try GoogleOAuthAuthorization(clientID: clientID, state: "state", verifier: verifier)
        let query = try XCTUnwrap(URLComponents(url: auth.url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
        XCTAssertEqual(auth.url.host, "accounts.google.com")
        XCTAssertEqual(values["scope"], "openid email profile")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(values["redirect_uri"], "com.googleusercontent.apps.123-ios:/")
        XCTAssertEqual(values["state"], "state")
        let first = try GoogleOAuthAuthorization.make(clientID: clientID)
        let second = try GoogleOAuthAuthorization.make(clientID: clientID)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.verifier.count, 43)
    }

    func testInvalidClientAndVerifierAreRejectedBeforeOpeningBrowser() throws {
        for id in ["", "$(GOOGLE_IOS_CLIENT_ID)", ".apps.googleusercontent.com", "bad/id.apps.googleusercontent.com"] {
            XCTAssertThrowsError(try GoogleOAuthAuthorization.make(clientID: id))
        }
        XCTAssertThrowsError(try GoogleOAuthAuthorization(clientID: clientID, state: "", verifier: verifier))
        for invalid in ["short", String(repeating: "a", count: 129), String(repeating: "+", count: 43)] {
            XCTAssertThrowsError(try GoogleOAuthAuthorization(clientID: clientID, state: "s", verifier: invalid))
        }
    }

    func testCallbackRequiresExactSchemePathStateAndSingleCode() throws {
        let auth = try GoogleOAuthAuthorization(clientID: clientID, state: "state", verifier: verifier)
        XCTAssertEqual(try auth.code(from: URL(string: auth.redirectURI + "?state=state&code=a%2Bb")!), "a+b")
        for callback in [
            "other:/?state=state&code=x", auth.callbackScheme + "://host/?state=state&code=x",
            auth.callbackScheme + ":/other?state=state&code=x", auth.redirectURI + "?code=x",
            auth.redirectURI + "?state=wrong&code=x", auth.redirectURI + "?state=state&state=state&code=x",
            auth.redirectURI + "?state=state&code=x&code=y",
            auth.redirectURI + "?state=state&state&code=x", auth.redirectURI + "?state=state&code=x&code",
            auth.redirectURI + "?state=state&code=",
            auth.redirectURI + "?state=state&error=failed", auth.redirectURI + "?state=state&code=x#fragment"
        ] {
            XCTAssertThrowsError(try auth.code(from: XCTUnwrap(URL(string: callback))))
        }
        XCTAssertThrowsError(try auth.code(from: URL(string: auth.redirectURI + "?state=state&error=access_denied")!)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testTokenExchangeEncodesSpecialCharactersWithoutSecret() throws {
        let auth = try GoogleOAuthAuthorization(clientID: clientID, state: "state", verifier: verifier)
        let request = auth.tokenRequest(code: "a+b&c=d")
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(try String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("code=a%2Bb%26c%3Dd"))
        XCTAssertTrue(body.contains("code_verifier=" + verifier))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testTokenResponseRequiresSuccessAndNonemptyIdentityToken() throws {
        XCTAssertEqual(
            try GoogleOAuthAuthorization.identityToken(data: Data(#"{"id_token":"id"}"#.utf8), status: 200),
            "id"
        )
        for body in ["{}", "invalid", #"{"id_token":" "}"#, #"{"id_token":1}"#] {
            XCTAssertThrowsError(try GoogleOAuthAuthorization.identityToken(data: Data(body.utf8), status: 200))
        }
        XCTAssertThrowsError(try GoogleOAuthAuthorization.identityToken(
            data: Data(#"{"id_token":"id"}"#.utf8),
            status: 401
        ))
        XCTAssertEqual(GoogleOAuthError.notConfigured.errorDescription, "Google sign-in is not configured.")
    }
}
