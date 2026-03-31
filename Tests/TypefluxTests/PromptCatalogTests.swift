import XCTest
@testable import Typeflux

final class PromptCatalogTests: XCTestCase {
    func testLanguageConsistencyRuleTargetsProcessedContent() {
        XCTAssertEqual(
            PromptCatalog.languageConsistencyRule(for: "selected text"),
            """
            Language consistency rule:
            You must keep the output language consistent with the original language of the selected text by default. Do not translate, paraphrase into another language, or switch languages because of persona defaults, style preferences, or formatting instructions alone. Only change the output language when a later instruction explicitly and clearly requires a different language.
            """
        )
    }

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
        XCTAssertTrue(prompts.system.contains(PromptCatalog.languageConsistencyRule(for: "source text")))
        XCTAssertTrue(prompts.system.contains("\"Section A - Raw transcript\" is the source content to rewrite"))
        XCTAssertTrue(prompts.user.contains("Section B - Persona requirements (style constraints, not source content):\nformal and concise"))
    }

    func testRewritePromptsIncludeLanguageConsistencyForSelectionEditing() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "你好，世界",
            spokenInstruction: "改得更自然一点",
            personaPrompt: "professional but warm"
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains(PromptCatalog.languageConsistencyRule(for: "selected text")))
        XCTAssertTrue(prompts.system.contains("text editing assistant"))
    }

    func testSelectionEditingPromptKeepsLanguageAlignedToSelectedText() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "Please send the proposal today.",
            spokenInstruction: "让语气更礼貌一些",
            personaPrompt: "Respond like a concise assistant."
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("original language of the selected text"))
        XCTAssertFalse(prompts.system.contains("latest input language"))
    }

    func testMultimodalTranscriptionPromptIncludesLanguageConsistencyRule() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: "Use concise business language.",
            vocabularyTerms: []
        )

        XCTAssertTrue(prompt.contains(PromptCatalog.languageConsistencyRule(for: "spoken content")))
        XCTAssertTrue(prompt.contains("Input semantics:"))
        XCTAssertTrue(prompt.contains("Persona requirements:"))
    }
}
