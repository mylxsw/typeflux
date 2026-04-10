@testable import Typeflux
import XCTest

final class TypefluxOfficialTranscriberTests: XCTestCase {
    func testReceiveFailureIsUnexpectedBeforeCompletionWithoutFinalSegments() {
        XCTAssertTrue(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: []
            ),
        )
    }

    func testReceiveFailureIsAcceptedAfterFinalSegmentWithoutCompletedEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: ["hello world"]
            ),
        )
    }

    func testReceiveFailureIsAcceptedAfterExplicitCompletionEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: true,
                finalSegments: []
            ),
        )
    }
}
