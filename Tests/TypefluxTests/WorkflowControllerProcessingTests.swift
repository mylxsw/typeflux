@testable import Typeflux
import XCTest

final class WorkflowControllerProcessingTests: XCTestCase {
    func testAskWithoutSelectionAgentDispositionMapsAnswerToAnswer() {
        let result = WorkflowController.askWithoutSelectionAgentDisposition(
            for: .answer("Here is the answer"),
        )

        XCTAssertEqual(result, .answer("Here is the answer"))
    }

    func testAskWithoutSelectionAgentDispositionMapsEditToInsert() {
        let result = WorkflowController.askWithoutSelectionAgentDisposition(
            for: .edit("Draft to insert"),
        )

        XCTAssertEqual(result, .insert("Draft to insert"))
    }
}
