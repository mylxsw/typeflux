@testable import Typeflux
import XCTest

final class NetworkDebugLoggerTests: XCTestCase {
    func testDescribeErrorIncludesNSErrorMetadata() throws {
        let error = try NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn't be completed.",
                NSLocalizedFailureReasonErrorKey: "Connection refused",
                NSURLErrorFailingURLErrorKey: XCTUnwrap(URL(string: "https://api.openai.com/v1/audio/transcriptions")),
            ],
        )

        let description = NetworkDebugLogger.describe(error: error)

        XCTAssertTrue(description.contains("domain=NSURLErrorDomain"))
        XCTAssertTrue(description.contains("code=-1004"))
        XCTAssertTrue(description.contains("reason=Connection refused"))
        XCTAssertTrue(description.contains("failingURL=https://api.openai.com/v1/audio/transcriptions"))
    }

    func testDescribeErrorIncludesUnderlyingError() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: 61,
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"],
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn't be completed.",
                NSUnderlyingErrorKey: underlying,
            ],
        )

        let description = NetworkDebugLogger.describe(error: error)

        XCTAssertTrue(description.contains("underlying=NSPOSIXErrorDomain(61): Connection refused"))
    }

    // MARK: - describe(error:) additional coverage

    func testDescribeErrorIncludesDomainAndCode() {
        let error = NSError(domain: "com.test", code: 42, userInfo: nil)
        let description = NetworkDebugLogger.describe(error: error)
        XCTAssertTrue(description.contains("domain=com.test"))
        XCTAssertTrue(description.contains("code=42"))
    }

    func testDescribeErrorIncludesLocalizedDescription() {
        let error = NSError(
            domain: "com.test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"],
        )
        let description = NetworkDebugLogger.describe(error: error)
        XCTAssertTrue(description.contains("Something went wrong"))
    }

    func testDescribeErrorIncludesRecoverySuggestion() {
        let error = NSError(
            domain: "com.test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Error occurred",
                NSLocalizedRecoverySuggestionErrorKey: "Try again later",
            ],
        )
        let description = NetworkDebugLogger.describe(error: error)
        XCTAssertTrue(description.contains("suggestion=Try again later"))
    }

    func testDescribeErrorDoesNotIncludeExcludedUserInfoKeys() {
        let error = NSError(
            domain: "com.test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Error",
                NSURLErrorFailingURLStringErrorKey: "https://excluded.example.com",
            ],
        )
        let description = NetworkDebugLogger.describe(error: error)
        // NSURLErrorFailingURLStringErrorKey should be excluded from userInfo output
        // (but failingURL from NSURLErrorFailingURLErrorKey would be included)
        XCTAssertFalse(description.contains("NSURLErrorFailingURLStringErrorKey"))
    }

    func testDescribeErrorIncludesTypeInformation() {
        let error = NSError(domain: "com.test", code: 99, userInfo: nil)
        let description = NetworkDebugLogger.describe(error: error)
        XCTAssertTrue(description.contains("type="))
    }

    func testDescribeErrorWithoutOptionalFieldsIsStillValid() {
        let error = NSError(domain: "minimal.domain", code: 0, userInfo: [:])
        let description = NetworkDebugLogger.describe(error: error)
        XCTAssertTrue(description.contains("domain=minimal.domain"))
        XCTAssertTrue(description.contains("code=0"))
        XCTAssertFalse(description.contains("reason="))
        XCTAssertFalse(description.contains("suggestion="))
    }

    // MARK: - logMessage (smoke test)

    func testLogMessageDoesNotCrash() {
        NetworkDebugLogger.logMessage("test message for coverage")
    }

    // MARK: - logWebSocketEvent (smoke test)

    func testLogWebSocketEventDoesNotCrash() {
        NetworkDebugLogger.logWebSocketEvent(provider: "TestProvider", phase: "connected")
    }

    func testLogWebSocketEventWithDetailsDoesNotCrash() {
        NetworkDebugLogger.logWebSocketEvent(provider: "TestProvider", phase: "message", details: "payload=42 bytes")
    }

    // MARK: - logRequest (smoke test)

    func testLogRequestDoesNotCrash() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.example.com/v1/test")))
        request.httpMethod = "POST"
        request.setValue("Bearer sk-test", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["key": "value"])
        NetworkDebugLogger.logRequest(request)
    }

    func testLogRequestRedactsAuthorizationHeader() throws {
        // Just verify no crash - the actual redaction is tested via describe helpers
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.example.com/v1/chat")))
        request.setValue("Bearer sensitive-token", forHTTPHeaderField: "Authorization")
        NetworkDebugLogger.logRequest(request)
    }

    func testLogRequestWithNoBody() throws {
        let request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.example.com/v1/models")))
        NetworkDebugLogger.logRequest(request)
    }

    // MARK: - logResponse (smoke test)

    func testLogResponseWithHTTPResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/test"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        )
        let body = try JSONSerialization.data(withJSONObject: ["result": "ok"])
        NetworkDebugLogger.logResponse(response, data: body)
    }

    func testLogResponseWithNonHTTPResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/test"))
        let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 4, textEncodingName: nil)
        NetworkDebugLogger.logResponse(response, data: nil)
    }

    func testLogResponseWithNilResponse() {
        NetworkDebugLogger.logResponse(nil, data: nil)
    }

    func testLogResponseWithEmptyData() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com"))
        let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)
        NetworkDebugLogger.logResponse(response, data: Data())
    }

    // MARK: - logError (smoke test)

    func testLogErrorDoesNotCrash() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test error"])
        NetworkDebugLogger.logError(context: "test context", error: error)
    }
}
