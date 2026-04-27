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
            vocabularyTerms: ["Typeflux"],
        )

        XCTAssertEqual(request.sourceText, "source")
        XCTAssertEqual(request.spokenInstruction, "make it better")
        XCTAssertEqual(request.personaPrompt, "formal tone")
        XCTAssertEqual(request.vocabularyTerms, ["Typeflux"])
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
        XCTAssertTrue(request.vocabularyTerms.isEmpty)
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
        XCTAssertTrue(prompts.user.contains("<metadata>"))
        XCTAssertTrue(prompts.user.contains("<app_name>\nNotes\n</app_name>"))
        XCTAssertTrue(prompts.user.contains("<active_text>"))
        XCTAssertTrue(prompts.user.contains("<text_before_cursor><![CDATA[\nProject Apollo will ship\n]]></text_before_cursor>"))
        XCTAssertTrue(prompts.user.contains("<cursor />"))
        XCTAssertTrue(prompts.user.contains("<text_after_cursor><![CDATA[\nafter QA signs off\n]]></text_after_cursor>"))
        XCTAssertTrue(prompts.user.contains("Project Apollo will ship"))
        XCTAssertTrue(prompts.user.contains("after QA signs off"))
    }

    func testRewritePromptMarksSelectedTextInsideInputContextWhenProvided() {
        let inputContext = InputContextSnapshot(
            appName: "Sublime Text",
            bundleIdentifier: "com.sublimetext.4",
            role: "AXWindow",
            isEditable: false,
            isFocusedTarget: true,
            prefix: "before",
            suffix: "after",
            selectedText: "selected",
        )
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "replacement",
            spokenInstruction: nil,
            personaPrompt: nil,
            inputContext: inputContext,
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.user.contains("<text_before_cursor><![CDATA[\nbefore\n]]></text_before_cursor>"))
        XCTAssertTrue(prompts.user.contains("<cursor />"))
        XCTAssertTrue(prompts.user.contains("<selected_text><![CDATA[\nselected\n]]></selected_text>"))
        XCTAssertTrue(prompts.user.contains("<text_after_cursor><![CDATA[\nafter\n]]></text_after_cursor>"))
    }
}
