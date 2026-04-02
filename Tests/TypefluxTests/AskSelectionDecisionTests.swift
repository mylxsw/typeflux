import XCTest
@testable import Typeflux

final class AskSelectionDecisionTests: XCTestCase {
    func testParseAnswerDecision() {
        let response = #"{"action":"answer","response":"This sentence is too informal."}"#

        let decision = AskSelectionDecision.parse(from: response)

        XCTAssertEqual(decision, AskSelectionDecision(action: .answer, response: "This sentence is too informal."))
    }

    func testParseEditDecisionAllowsEmptyResponse() {
        let response = #"{"action":"edit","response":""}"#

        let decision = AskSelectionDecision.parse(from: response)

        XCTAssertEqual(decision, AskSelectionDecision(action: .edit, response: ""))
    }

    func testParseRejectsUnknownAction() {
        let response = #"{"action":"rewrite","response":"nope"}"#

        XCTAssertNil(AskSelectionDecision.parse(from: response))
    }

    func testParseRejectsMissingResponseField() {
        let response = #"{"action":"answer"}"#

        XCTAssertNil(AskSelectionDecision.parse(from: response))
    }

    func testParseAcceptsFencedJSONDecision() {
        let response = """
        ```json
        {
          "action": "edit",
          "response": ""
        }
        ```
        """

        let decision = AskSelectionDecision.parse(from: response)

        XCTAssertEqual(decision, AskSelectionDecision(action: .edit, response: ""))
    }

    func testParseAcceptsJSONEmbeddedInSurroundingText() {
        let response = """
        Here is the result:
        {"action":"answer","response":"Translated text goes here."}
        """

        let decision = AskSelectionDecision.parse(from: response)

        XCTAssertEqual(decision, AskSelectionDecision(action: .answer, response: "Translated text goes here."))
    }

    func testParseAcceptsDecisionAliasKey() {
        let response = """
        {
          "decision": "edit",
          "response": ""
        }
        """

        let decision = AskSelectionDecision.parse(from: response)

        XCTAssertEqual(decision, AskSelectionDecision(action: .edit, response: ""))
    }

    func testParseOrDefaultToAnswerFallsBackForPlainText() {
        let response = "This paragraph sounds hesitant because it overuses qualifiers."

        let decision = AskSelectionDecision.parseOrDefaultToAnswer(from: response)

        XCTAssertEqual(
            decision,
            AskSelectionDecision(
                action: .answer,
                response: "This paragraph sounds hesitant because it overuses qualifiers."
            )
        )
    }

    func testParseOrDefaultToAnswerRejectsBlankFallback() {
        XCTAssertNil(AskSelectionDecision.parseOrDefaultToAnswer(from: "   \n  "))
    }
}
