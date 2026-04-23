@testable import Typeflux
import XCTest

final class LLMHTTPSessionTests: XCTestCase {
    func testSharedSessionDoesNotUseAggressivePerRequestTimeout() {
        let configuration = LLMHTTPSession.shared.configuration

        XCTAssertNotEqual(configuration.timeoutIntervalForRequest, 15, accuracy: 0.001)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 120, accuracy: 0.001)
    }
}
