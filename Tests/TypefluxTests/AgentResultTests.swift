@testable import Typeflux
import XCTest

final class AgentResultTests: XCTestCase {
    // MARK: - answerText

    func testAnswerTextFromDirectText() {
        let result = AgentResult(
            outcome: .text("Hello, world!"),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertEqual(result.answerText, "Hello, world!")
    }

    func testAnswerTextFromEmptyTextReturnsNil() {
        let result = AgentResult(
            outcome: .text(""),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.answerText)
    }

    func testAnswerTextFromTerminationTool() {
        let json = #"{"answer": "The answer is 42"}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "answer_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertEqual(result.answerText, "The answer is 42")
    }

    func testAnswerTextFromWrongToolReturnsNil() {
        let json = #"{"replacement": "new text"}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "edit_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.answerText)
    }

    func testAnswerTextFromInvalidJSONReturnsNil() {
        let result = AgentResult(
            outcome: .terminationTool(name: "answer_text", argumentsJSON: "not json"),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.answerText)
    }

    func testAnswerTextFromMaxStepsReturnsNil() {
        let result = AgentResult(
            outcome: .maxStepsReached,
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.answerText)
    }

    func testAnswerTextFromMissingFieldReturnsNil() {
        let json = #"{"other_field": "value"}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "answer_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.answerText)
    }

    // MARK: - editedText

    func testEditedTextFromEditTool() {
        let json = #"{"replacement": "improved text"}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "edit_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertEqual(result.editedText, "improved text")
    }

    func testEditedTextFromWrongToolReturnsNil() {
        let json = #"{"answer": "some answer"}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "answer_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.editedText)
    }

    func testEditedTextFromDirectTextReturnsNil() {
        let result = AgentResult(
            outcome: .text("plain text"),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.editedText)
    }

    func testEditedTextFromInvalidJSONReturnsNil() {
        let result = AgentResult(
            outcome: .terminationTool(name: "edit_text", argumentsJSON: "{bad json"),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.editedText)
    }

    func testEditedTextFromNonStringFieldReturnsNil() {
        let json = #"{"replacement": 42}"#
        let result = AgentResult(
            outcome: .terminationTool(name: "edit_text", argumentsJSON: json),
            steps: [],
            totalDurationMs: 100,
        )
        XCTAssertNil(result.editedText)
    }
}
