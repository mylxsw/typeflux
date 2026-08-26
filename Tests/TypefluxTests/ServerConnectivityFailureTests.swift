@testable import Typeflux
import XCTest

final class ServerConnectivityFailureTests: XCTestCase {
    func testMatchesURLAndNestedCloudExecutorConnectivityFailures() {
        XCTAssertTrue(ServerConnectivityFailure.matches(URLError(.notConnectedToInternet)))
        XCTAssertTrue(ServerConnectivityFailure.matches(
            CloudRequestExecutorError.allEndpointsFailed(
                lastError: URLError(.cannotConnectToHost)
            )
        ))
    }

    func testMatchesUnderlyingAndUserFacingConnectionErrors() {
        let wrapped = NSError(
            domain: "Wrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )
        let userFacing = NSError(
            domain: "WebSocket",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]
        )

        XCTAssertTrue(ServerConnectivityFailure.matches(wrapped))
        XCTAssertTrue(ServerConnectivityFailure.matches(userFacing))
    }

    func testRejectsCancellationAndApplicationErrors() {
        XCTAssertFalse(ServerConnectivityFailure.matches(URLError(.cancelled)))
        XCTAssertFalse(ServerConnectivityFailure.matches(
            NSError(
                domain: "RemoteSTT",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Unauthorized"]
            )
        ))
    }
}
