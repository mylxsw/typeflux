@testable import Typeflux
import XCTest

final class LLMRewriteRequestTests: XCTestCase {
    func testModeEnumCases() {
        let editSelection = LLMRewriteRequest.Mode.editSelection
        let rewriteTranscript = LLMRewriteRequest.Mode.rewriteTranscript

        // Ensure both cases are distinct.
        XCTAssertFalse(editSelection == rewriteTranscript)
    }

    func testCanCreateRequestWithAllParameters() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "source",
            spokenInstruction: "make it better",
            personaPrompt: "formal tone",
        )

        XCTAssertEqual(request.sourceText, "source")
        XCTAssertEqual(request.spokenInstruction, "make it better")
        XCTAssertEqual(request.personaPrompt, "formal tone")
    }

    func testCanCreateRequestWithNilOptionals() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "raw text",
            spokenInstruction: nil,
            personaPrompt: nil,
        )

        XCTAssertEqual(request.sourceText, "raw text")
        XCTAssertNil(request.spokenInstruction)
        XCTAssertNil(request.personaPrompt)
    }
}
