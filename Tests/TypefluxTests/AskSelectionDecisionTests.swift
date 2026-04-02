import XCTest
@testable import Typeflux

final class AskSelectionDecisionTests: XCTestCase {
    func testAnswerDecisionRequiresNonEmptyResponse() {
        XCTAssertTrue(AskSelectionDecision(action: .answer, response: "Final answer").isValid)
        XCTAssertFalse(AskSelectionDecision(action: .answer, response: "  ").isValid)
    }

    func testEditDecisionRequiresEmptyResponse() {
        XCTAssertTrue(AskSelectionDecision(action: .edit, response: "").isValid)
        XCTAssertTrue(AskSelectionDecision(action: .edit, response: "   ").isValid)
        XCTAssertFalse(AskSelectionDecision(action: .edit, response: "rewrite me").isValid)
    }

    func testDecodesFromToolArgumentsJSON() throws {
        let data = Data(#"{"action":"answer","response":"This sentence is too informal."}"#.utf8)

        let decision = try JSONDecoder().decode(AskSelectionDecision.self, from: data)

        XCTAssertEqual(
            decision,
            AskSelectionDecision(action: .answer, response: "This sentence is too informal.")
        )
    }

    func testToolSchemaRequiresActionAndResponse() {
        let properties = AskSelectionDecision.schema.jsonObject["properties"] as? [String: Any]
        let actionSchema = properties?["action"] as? [String: Any]
        let actionEnum = actionSchema?["enum"] as? [String]
        let required = AskSelectionDecision.schema.jsonObject["required"] as? [String]

        XCTAssertEqual(AskSelectionDecision.tool.name, "answer_or_edit_selection")
        XCTAssertEqual(actionEnum, ["answer", "edit"])
        XCTAssertEqual(required ?? [], ["action", "response"])
    }
}
