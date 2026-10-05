import Foundation
import XCTest
@testable import TypefluxChat

final class ChatAuthenticationErrorTests: XCTestCase {
    func testOAuthRejectionPreservesTheServerCode() {
        let body = Data(#"{"code":"AUTH_OAUTH_INVALID_TOKEN","message":"invalid OAuth token"}"#.utf8)
        XCTAssertThrowsError(try ChatRequest.decode(ChatSession.self, data: body, statusCode: 401)) {
            XCTAssertEqual($0 as? ChatAPIError,
                           .server(code: "AUTH_OAUTH_INVALID_TOKEN", message: "invalid OAuth token"))
        }
    }

    func testOAuthRejectionDoesNotRequireAMessage() {
        let body = Data(#"{"code":"AUTH_OAUTH_INVALID_TOKEN"}"#.utf8)
        XCTAssertThrowsError(try ChatRequest.decode(ChatSession.self, data: body, statusCode: 401)) {
            XCTAssertEqual($0 as? ChatAPIError, .server(code: "AUTH_OAUTH_INVALID_TOKEN", message: nil))
        }
    }

    func testPasswordSessionAndNonJSONRejectionsRemainUnauthorized() {
        for body in [
            "Unauthorized",
            #"{"code":"AUTH_INVALID_CREDENTIALS","message":"invalid credentials"}"#,
            #"{"code":"AUTH_REFRESH_TOKEN_INVALID","message":"invalid refresh token"}"#,
            #"{"message":"expired session"}"#
        ] {
            XCTAssertThrowsError(try ChatRequest.decode(ChatSession.self, data: Data(body.utf8), statusCode: 401)) {
                XCTAssertEqual($0 as? ChatAPIError, .unauthorized)
            }
        }
    }
}
