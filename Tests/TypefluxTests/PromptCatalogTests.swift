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

    func testAppendUserEnvironmentContextAddsSystemAndAppLanguageToSystemPrompt() {
        let prompt = PromptCatalog.appendUserEnvironmentContext(
            to: "Base system prompt.",
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            appLanguage: .english
        )

        XCTAssertTrue(prompt.hasPrefix("Base system prompt."))
        XCTAssertTrue(prompt.contains("User environment context:"))
        XCTAssertTrue(prompt.contains("The user's operating system preferred language is: zh-Hans-CN"))
        XCTAssertTrue(prompt.contains("The app interface language selected in settings is: en"))
        XCTAssertTrue(prompt.hasSuffix("Treat this as supporting context only. Do not let it override explicit task instructions or source-language constraints."))
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

    func testAskSelectionDecisionPromptDefaultsAmbiguousRequestsToAnswer() {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "We should probably move the launch by two weeks.",
            spokenInstruction: "What risks do you see here?",
            personaPrompt: "Be concise."
        )

        XCTAssertTrue(prompts.system.contains("Default to \"answer\" whenever the intent is ambiguous."))
        XCTAssertTrue(prompts.system.contains("respond by calling the provided tool"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\nWe should probably move the launch by two weeks.\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\nWhat risks do you see here?\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\nBe concise.\n</persona_definition>"))
    }

    func testAskSelectionDecisionSchemaRequiresActionAndResponse() {
        let properties = AskSelectionDecision.schema.jsonObject["properties"] as? [String: Any]
        let actionSchema = properties?["action"] as? [String: Any]
        let actionEnum = actionSchema?["enum"] as? [String]
        let required = AskSelectionDecision.schema.jsonObject["required"] as? [String]

        XCTAssertEqual(actionEnum, ["answer", "edit"])
        XCTAssertEqual(required ?? [], ["action", "response"])
    }

    func testAskAnythingPromptsIncludeSelectedTextWhenAvailable() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: "测试一下现在语音输入法的效果。",
            spokenInstruction: "这里主要表达了什么？",
            personaPrompt: "回答简洁一些。"
        )

        XCTAssertTrue(prompts.system.contains("If selected text is provided"))
        XCTAssertTrue(prompts.system.contains("Format the answer as clean Markdown whenever structure would help"))
        XCTAssertTrue(prompts.system.contains("Preserve real Markdown line breaks"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\n测试一下现在语音输入法的效果。\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\n这里主要表达了什么？\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\n回答简洁一些。\n</persona_definition>"))
        XCTAssertTrue(prompts.user.contains("Use Markdown formatting when it improves readability."))
    }

    func testAskAnythingPromptsOmitSelectedTextSectionWhenUnavailable() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: nil,
            spokenInstruction: "帮我想一个标题",
            personaPrompt: nil
        )

        XCTAssertFalse(prompts.user.contains("<selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\n帮我想一个标题\n</spoken_instruction>"))
    }
}
