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
        XCTAssertFalse(prompts.system.contains(PromptCatalog.languageConsistencyRule(for: "source text")))
        XCTAssertTrue(prompts.system.contains("\"<raw_transcript>\" is the source content to rewrite"))
        XCTAssertTrue(prompts.user.contains("<raw_transcript>\nraw text\n</raw_transcript>"))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\nformal and concise\n</persona_definition>"))
        XCTAssertTrue(prompts.user.contains(PromptCatalog.languageConsistencyRule(for: "source text")))
    }

    func testRewritePromptsIncludeLanguageConsistencyForSelectionEditing() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "你好，世界",
            spokenInstruction: "改得更自然一点",
            personaPrompt: "professional but warm"
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertFalse(prompts.system.contains(PromptCatalog.languageConsistencyRule(for: "selected text")))
        XCTAssertTrue(prompts.system.contains("text editing assistant"))
        XCTAssertTrue(prompts.user.contains(PromptCatalog.languageConsistencyRule(for: "selected text")))
    }

    func testSelectionEditingPromptKeepsLanguageAlignedToSelectedText() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "Please send the proposal today.",
            spokenInstruction: "让语气更礼貌一些",
            personaPrompt: "Respond like a concise assistant."
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.user.contains("original language of the selected text"))
        XCTAssertFalse(prompts.user.contains("latest input language"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\nPlease send the proposal today.\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\n让语气更礼貌一些\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\nRespond like a concise assistant.\n</persona_definition>"))
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
