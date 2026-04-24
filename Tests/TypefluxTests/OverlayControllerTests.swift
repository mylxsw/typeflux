@testable import Typeflux
import XCTest

final class OverlayControllerTests: XCTestCase {
    func testWrapFailureActionsRunsDismissBeforeOriginalHandler() {
        var events: [String] = []
        let wrapped = OverlayController.wrapFailureActions(
            [
                OverlayFailureAction(
                    title: "Login",
                    isRetry: false,
                    handler: { events.append("action") },
                ),
            ],
            beforeAction: { events.append("dismiss") },
        )

        XCTAssertEqual(wrapped.count, 1)

        wrapped[0].handler()

        XCTAssertEqual(events, ["dismiss", "action"])
    }

    func testWrapFailureActionsPreservesMetadata() {
        let wrapped = OverlayController.wrapFailureActions(
            [
                OverlayFailureAction(
                    title: "Retry",
                    isRetry: true,
                    handler: {},
                ),
            ],
            beforeAction: {},
        )

        XCTAssertEqual(wrapped[0].title, "Retry")
        XCTAssertTrue(wrapped[0].isRetry)
    }
}
