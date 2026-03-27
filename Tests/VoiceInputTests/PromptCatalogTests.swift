import XCTest
@testable import VoiceInput

final class PromptCatalogTests: XCTestCase {
    func testTranscriptionVocabularyHintFiltersBlanks() {
        let hint = PromptCatalog.transcriptionVocabularyHint(terms: [" alpha ", "", "beta"])

        XCTAssertEqual(
            hint,
            """
            Recognize these words and phrases accurately, preserving their spelling and casing when possible:
            alpha, beta
            """
        )
    }

    func testRewritePromptsIncludePersonaForTranscriptRewrite() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "raw text",
            spokenInstruction: nil,
            personaPrompt: "formal and concise"
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("polished final copy"))
        XCTAssertTrue(prompts.user.contains("Persona requirements:\nformal and concise"))
    }
}
