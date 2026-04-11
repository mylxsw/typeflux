@testable import Typeflux
import XCTest

final class ConnectionTestSupportTests: XCTestCase {
    func testRunWithTimeoutReturnsOperationResultBeforeDeadline() async throws {
        let result = try await ConnectionTestSupport.runWithTimeout {
            "ok"
        }

        XCTAssertEqual(result, "ok")
    }

    func testRunWithTimeoutThrowsTimeoutErrorAfterDeadline() async {
        do {
            _ = try await ConnectionTestSupport.runWithTimeout {
                try await Task.sleep(for: .seconds(ConnectionTestSupport.timeoutSeconds + 1))
                return "late"
            }
            XCTFail("Expected timeout to be thrown")
        } catch let error as ConnectionTestError {
            XCTAssertEqual(error, .timedOut(seconds: ConnectionTestSupport.timeoutSeconds))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
