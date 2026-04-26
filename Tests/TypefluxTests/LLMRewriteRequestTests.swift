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

    func testRewritePromptIncludesInputContextWhenProvided() {
        let inputContext = InputContextSnapshot(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            isEditable: true,
            isFocusedTarget: true,
            prefix: "Project Apollo will ship",
            suffix: "after QA signs off",
            selectedText: nil,
        )
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "next Friday",
            spokenInstruction: nil,
            personaPrompt: nil,
            inputContext: inputContext,
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("<input_context>"))
        XCTAssertTrue(prompts.user.contains("<input_context>"))
        XCTAssertTrue(prompts.user.contains("Project Apollo will ship"))
        XCTAssertTrue(prompts.user.contains("after QA signs off"))
    }
}
