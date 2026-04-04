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

    // MARK: - Action Raw Values

    func testActionRawValues() {
        XCTAssertEqual(AskSelectionDecision.Action.answer.rawValue, "answer")
        XCTAssertEqual(AskSelectionDecision.Action.edit.rawValue, "edit")
    }

    // MARK: - Codable Round Trip

    func testCodableRoundTrip() throws {
        let original = AskSelectionDecision(action: .answer, response: "Polished text")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskSelectionDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEditCodableRoundTrip() throws {
        let original = AskSelectionDecision(action: .edit, response: "")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskSelectionDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - trimmedResponse

    func testTrimmedResponseTrimsWhitespace() {
        let decision = AskSelectionDecision(action: .answer, response: "  hello world \n")
        XCTAssertEqual(decision.trimmedResponse, "hello world")
    }

    func testTrimmedResponsePreservesInternalWhitespace() {
        let decision = AskSelectionDecision(action: .answer, response: "hello   world")
        XCTAssertEqual(decision.trimmedResponse, "hello   world")
    }

    // MARK: - isValid Edge Cases

    func testAnswerWithOnlyNewlinesIsInvalid() {
        XCTAssertFalse(AskSelectionDecision(action: .answer, response: "\n\n").isValid)
    }

    func testAnswerWithEmptyStringIsInvalid() {
        XCTAssertFalse(AskSelectionDecision(action: .answer, response: "").isValid)
    }

    func testEditWithNonEmptyResponseIsInvalid() {
        XCTAssertFalse(AskSelectionDecision(action: .edit, response: "some text").isValid)
    }

    func testEditWithWhitespaceOnlyIsValid() {
        XCTAssertTrue(AskSelectionDecision(action: .edit, response: "  \n  ").isValid)
    }

    // MARK: - Schema and Tool

    func testSchemaHasCorrectName() {
        XCTAssertEqual(AskSelectionDecision.schema.name, "answer_or_edit_selection")
    }

    func testToolHasDescription() {
        XCTAssertFalse(AskSelectionDecision.tool.description.isEmpty)
    }
}
