@testable import Typeflux
import XCTest

final class AskSelectionDecisionTests: XCTestCase {
    func testAnswerDecisionRequiresNonEmptyContent() {
        XCTAssertTrue(AskSelectionDecision(answerEdit: .answer, content: "Final answer").isValid)
        XCTAssertFalse(AskSelectionDecision(answerEdit: .answer, content: "  ").isValid)
    }

    func testEditDecisionRequiresNonEmptyContent() {
        XCTAssertTrue(AskSelectionDecision(answerEdit: .edit, content: "rewrite me").isValid)
        XCTAssertFalse(AskSelectionDecision(answerEdit: .edit, content: "").isValid)
        XCTAssertFalse(AskSelectionDecision(answerEdit: .edit, content: "   ").isValid)
    }

    func testDecodesFromNewToolArgumentsJSON() throws {
        let data = Data(#"{"answer_edit":"answer","content":"This sentence is too informal."}"#.utf8)

        let decision = try JSONDecoder().decode(AskSelectionDecision.self, from: data)

        XCTAssertEqual(
            decision,
            AskSelectionDecision(answerEdit: .answer, content: "This sentence is too informal."),
        )
    }

    func testDecodesFromLegacyToolArgumentsJSON() throws {
        let data = Data(#"{"action":"edit","response":"Rewrite result"}"#.utf8)

        let decision = try JSONDecoder().decode(AskSelectionDecision.self, from: data)

        XCTAssertEqual(
            decision,
            AskSelectionDecision(answerEdit: .edit, content: "Rewrite result"),
        )
    }

    func testToolSchemaRequiresAnswerEditAndContent() {
        let properties = AskSelectionDecision.schema.jsonObject["properties"] as? [String: Any]
        let actionSchema = properties?["answer_edit"] as? [String: Any]
        let actionEnum = actionSchema?["enum"] as? [String]
        let required = AskSelectionDecision.schema.jsonObject["required"] as? [String]

        XCTAssertEqual(AskSelectionDecision.tool.name, "answer_or_edit_selection")
        XCTAssertEqual(actionEnum, ["answer", "edit"])
        XCTAssertEqual(required ?? [], ["answer_edit", "content"])
    }

    // MARK: - AnswerEdit Raw Values

    func testAnswerEditRawValues() {
        XCTAssertEqual(AskSelectionDecision.AnswerEdit.answer.rawValue, "answer")
        XCTAssertEqual(AskSelectionDecision.AnswerEdit.edit.rawValue, "edit")
    }

    // MARK: - Codable Round Trip

    func testCodableRoundTrip() throws {
        let original = AskSelectionDecision(answerEdit: .answer, content: "Polished text")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskSelectionDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEditCodableRoundTrip() throws {
        let original = AskSelectionDecision(answerEdit: .edit, content: "Edited text")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskSelectionDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - trimmedContent

    func testTrimmedContentTrimsWhitespace() {
        let decision = AskSelectionDecision(answerEdit: .answer, content: "  hello world \n")
        XCTAssertEqual(decision.trimmedContent, "hello world")
    }

    func testTrimmedContentPreservesInternalWhitespace() {
        let decision = AskSelectionDecision(answerEdit: .answer, content: "hello   world")
        XCTAssertEqual(decision.trimmedContent, "hello   world")
    }

    // MARK: - isValid Edge Cases

    func testAnswerWithOnlyNewlinesIsInvalid() {
        XCTAssertFalse(AskSelectionDecision(answerEdit: .answer, content: "\n\n").isValid)
    }

    func testAnswerWithEmptyStringIsInvalid() {
        XCTAssertFalse(AskSelectionDecision(answerEdit: .answer, content: "").isValid)
    }

    func testEditWithNonEmptyContentIsValid() {
        XCTAssertTrue(AskSelectionDecision(answerEdit: .edit, content: "some text").isValid)
    }

    func testEditWithWhitespaceOnlyIsValid() {
        XCTAssertFalse(AskSelectionDecision(answerEdit: .edit, content: "  \n  ").isValid)
    }

    // MARK: - Schema and Tool

    func testSchemaHasCorrectName() {
        XCTAssertEqual(AskSelectionDecision.schema.name, "answer_or_edit_selection")
    }

    func testToolHasDescription() {
        XCTAssertFalse(AskSelectionDecision.tool.description.isEmpty)
    }
}
