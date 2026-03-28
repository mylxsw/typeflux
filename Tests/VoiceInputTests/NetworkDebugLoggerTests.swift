import XCTest
@testable import VoiceInput

final class NetworkDebugLoggerTests: XCTestCase {
    func testDescribeErrorIncludesNSErrorMetadata() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed.",
                NSLocalizedFailureReasonErrorKey: "Connection refused",
                NSURLErrorFailingURLErrorKey: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            ]
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
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed.",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let description = NetworkDebugLogger.describe(error: error)

        XCTAssertTrue(description.contains("underlying=NSPOSIXErrorDomain(61): Connection refused"))
    }
}
