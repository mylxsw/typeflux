@testable import Typeflux
import XCTest

final class PromptCatalogTests: XCTestCase {
    func testLanguageConsistencyRuleTargetsProcessedContent() {
        XCTAssertEqual(
            PromptCatalog.languageConsistencyRule(for: "selected text"),
            """
            Language consistency rule:
            You must keep the output language consistent with the original language of the selected text by default. Do not translate, paraphrase into another language, or switch languages because of persona defaults, style preferences, or formatting instructions alone. Only change the output language when a later instruction explicitly and clearly requires a different language.
            """,
        )
    }

    func testAppendUserEnvironmentContextAddsSystemAndAppLanguageToSystemPrompt() {
        let prompt = PromptCatalog.appendUserEnvironmentContext(
            to: "Base system prompt.",
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            appLanguage: .english,
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
            <vocabulary_hints>
            <instruction>
            Recognize these words and phrases accurately, preserving their spelling and casing when possible. Do not emit any term unless it is actually spoken in the audio.
            </instruction>
            <terms>
            alpha, beta
            </terms>
            </vocabulary_hints>
            """,
        )
    }

    func testRewritePromptsIncludePersonaForTranscriptRewrite() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "raw text",
            spokenInstruction: nil,
            personaPrompt: "formal and concise",
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
            personaPrompt: "professional but warm",
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
            personaPrompt: "Respond like a concise assistant.",
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
            vocabularyTerms: ["Typeflux"],
        )

        XCTAssertTrue(prompt.contains("You are a multimodal speech transcription and rewrite engine."))
        XCTAssertTrue(prompt.contains("<rules>"))
        XCTAssertTrue(prompt.contains("<language_policy>"))
        XCTAssertTrue(prompt.contains(PromptCatalog.languageConsistencyRule(for: "spoken content")))
        XCTAssertTrue(prompt.contains("<input_semantics>"))
        XCTAssertTrue(prompt.contains("<task_procedure>"))
        XCTAssertTrue(prompt.contains("<fidelity_requirements>"))
        XCTAssertTrue(prompt.contains("<output_contract>"))
        XCTAssertTrue(prompt.contains("<persona_definition>\nUse concise business language.\n</persona_definition>"))
        XCTAssertTrue(prompt.contains("<vocabulary_hints>"))
        XCTAssertTrue(prompt.contains("<terms>\nTypeflux\n</terms>"))
        XCTAssertTrue(prompt.contains("Do not output the intermediate transcript."))
        XCTAssertTrue(prompt.contains("Preserve all critical information from the speech"))
        XCTAssertTrue(prompt.contains("For very short or fragmentary utterances"))
        XCTAssertTrue(prompt.contains("When persona style conflicts with completeness or fidelity"))
    }

    func testAskSelectionDecisionPromptDefaultsAmbiguousRequestsToAnswer() {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "We should probably move the launch by two weeks.",
            spokenInstruction: "What risks do you see here?",
            personaPrompt: "Be concise.",
            editableTarget: true,
        )

        XCTAssertTrue(prompts.system.contains("Default to \"answer\" whenever the intent is ambiguous."))
        XCTAssertTrue(prompts.system.contains("single-shot \"Ask Anything\" requests"))
        XCTAssertTrue(prompts.system.contains("final answer in the \"content\" field"))
        XCTAssertTrue(prompts.system.contains("final rewritten text in the \"content\" field"))
        XCTAssertTrue(prompts.system.contains("If <editable_target> is false, you must choose \"answer\""))
        XCTAssertTrue(prompts.system.contains("respond by calling the provided tool"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\nWe should probably move the launch by two weeks.\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\nWhat risks do you see here?\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<editable_target>true</editable_target>"))
        XCTAssertFalse(prompts.user.contains("<persona_definition>"))
    }

    func testAskSelectionDecisionPromptMarksReadOnlyTargetsAsAnswerOnly() {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "Please make this more formal.",
            spokenInstruction: "Rewrite this",
            personaPrompt: nil,
            editableTarget: false,
        )

        XCTAssertTrue(prompts.user.contains("<editable_target>false</editable_target>"))
        XCTAssertTrue(prompts.user.contains("keep \"answer_edit\" set to \"answer\""))
    }

    func testAskSelectionDecisionPromptOmitsEditableTargetWhenUnknown() {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "Please make this more formal.",
            spokenInstruction: "Rewrite this",
            personaPrompt: nil,
            editableTarget: nil,
        )

        XCTAssertFalse(prompts.user.contains("<editable_target>"))
    }

    func testAskSelectionDecisionPromptTreatsCommandStyleWritingRequestsAsEdit() {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "This email sounds rough.",
            spokenInstruction: "Help me polish this",
            personaPrompt: nil,
            editableTarget: true,
        )

        XCTAssertTrue(prompts.system.contains("imperative writing or rewriting instruction"))
        XCTAssertTrue(prompts.system.contains("help me write this"))
        XCTAssertTrue(prompts.system.contains("帮我改"))
        XCTAssertTrue(prompts.user.contains("Help me polish this"))
        XCTAssertTrue(prompts.user.contains("should be treated as \"edit\""))
    }

    func testAskSelectionDecisionSchemaRequiresAnswerEditAndContent() {
        let properties = AskSelectionDecision.schema.jsonObject["properties"] as? [String: Any]
        let actionSchema = properties?["answer_edit"] as? [String: Any]
        let actionEnum = actionSchema?["enum"] as? [String]
        let required = AskSelectionDecision.schema.jsonObject["required"] as? [String]

        XCTAssertEqual(actionEnum, ["answer", "edit"])
        XCTAssertEqual(required ?? [], ["answer_edit", "content"])
    }

    func testAskAnythingPromptsIncludeSelectedTextWhenAvailable() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: "测试一下现在语音输入法的效果。",
            spokenInstruction: "这里主要表达了什么？",
            personaPrompt: "回答简洁一些。",
            targetContext: PromptCatalog.AskTargetContext(editableTarget: false),
        )

        XCTAssertTrue(prompts.system.contains("If selected text is provided"))
        XCTAssertTrue(prompts.system.contains("Interpret imperative writing or rewriting instructions as requests for final output"))
        XCTAssertTrue(prompts.system.contains("If <editable_target> is false, you must choose \"answer\""))
        XCTAssertTrue(prompts.system.contains("Format the answer as clean Markdown whenever structure would help"))
        XCTAssertTrue(prompts.system.contains("Preserve real Markdown line breaks"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\n测试一下现在语音输入法的效果。\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\n这里主要表达了什么？\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<editable_target>false</editable_target>"))
        XCTAssertFalse(prompts.user.contains("<persona_definition>"))
        XCTAssertTrue(prompts.user.contains("Use Markdown formatting when it improves readability."))
    }

    func testAskAnythingPromptsReuseSharedWritingIntentGuidance() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: "This draft is awkward.",
            spokenInstruction: "Help me polish this",
            personaPrompt: nil,
            targetContext: PromptCatalog.AskTargetContext(editableTarget: true),
        )

        XCTAssertTrue(prompts.system.contains("help me polish this"))
        XCTAssertTrue(prompts.user.contains("If the user is effectively asking you to draft, rewrite, polish, or improve text"))
        XCTAssertTrue(prompts.user.contains("<selected_text>\nThis draft is awkward.\n</selected_text>"))
        XCTAssertTrue(prompts.user.contains("<editable_target>true</editable_target>"))
    }

    func testAskPromptsUseSharedSystemGuidanceWithoutPersonaInstructions() {
        let decisionPrompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: "Original text",
            spokenInstruction: "Help me rewrite this",
            personaPrompt: "Be concise.",
            editableTarget: true,
        )
        let answerPrompts = PromptCatalog.askAnythingPrompts(
            selectedText: "Original text",
            spokenInstruction: "Help me rewrite this",
            personaPrompt: "Be concise.",
            targetContext: PromptCatalog.AskTargetContext(editableTarget: true),
        )

        XCTAssertTrue(decisionPrompts.system.contains("Interpret imperative writing or rewriting instructions as requests for final output"))
        XCTAssertTrue(answerPrompts.system.contains("Interpret imperative writing or rewriting instructions as requests for final output"))
        XCTAssertFalse(decisionPrompts.system.contains("Persona instructions"))
        XCTAssertFalse(answerPrompts.system.contains("Persona instructions"))
        XCTAssertFalse(decisionPrompts.user.contains("<persona_definition>"))
        XCTAssertFalse(answerPrompts.user.contains("<persona_definition>"))
    }

    func testAskAnythingPromptsOmitSelectedTextSectionWhenUnavailable() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: nil,
            spokenInstruction: "帮我想一个标题",
            personaPrompt: nil,
            targetContext: PromptCatalog.AskTargetContext(editableTarget: false),
        )

        XCTAssertFalse(prompts.user.contains("<selected_text>"))
        XCTAssertTrue(prompts.user.contains("<spoken_instruction>\n帮我想一个标题\n</spoken_instruction>"))
        XCTAssertTrue(prompts.user.contains("<editable_target>false</editable_target>"))
    }

    // MARK: - xmlSection

    func testXmlSectionWrapsContentInTags() {
        let result = PromptCatalog.xmlSection(tag: "example", content: "hello")
        XCTAssertEqual(result, "<example>\nhello\n</example>")
    }

    // MARK: - userEnvironmentContext

    func testUserEnvironmentContextWithCustomLanguages() {
        let context = PromptCatalog.userEnvironmentContext(
            preferredLanguages: ["ja-JP"],
            appLanguage: .japanese,
        )

        XCTAssertTrue(context.contains("User environment context:"))
        XCTAssertTrue(context.contains("ja-JP"))
        XCTAssertTrue(context.contains("ja"))
    }

    // MARK: - appendUserEnvironmentContext with empty prompt

    func testAppendUserEnvironmentContextWithEmptyPromptReturnsJustEnvironmentContext() {
        let result = PromptCatalog.appendUserEnvironmentContext(
            to: "",
            preferredLanguages: ["en-US"],
            appLanguage: .english,
        )

        XCTAssertTrue(result.contains("User environment context:"))
        XCTAssertFalse(result.hasPrefix("\n"))
    }

    // MARK: - multimodalTranscriptionSystemPrompt without persona

    func testMultimodalTranscriptionPromptWithoutPersona() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: [],
        )

        XCTAssertTrue(prompt.contains("You are a multimodal speech transcription engine."))
        XCTAssertFalse(prompt.contains("rewrite engine"))
        XCTAssertTrue(prompt.contains("Return only the final transcript text."))
        XCTAssertTrue(prompt.contains("preserve the speaker's meaning, intent, wording, and natural phrasing"))
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    func testRewriteTranscriptPromptProtectsShortUtteranceIntent() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "send today",
            spokenInstruction: nil,
            personaPrompt: "Make it polished and concise.",
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("preserve the user's full intent and every critical detail"))
        XCTAssertTrue(prompts.system.contains("unless they would cause information loss or change the user's meaning"))
        XCTAssertTrue(prompts.user.contains("For very short transcripts, be especially careful not to over-compress."))
        XCTAssertTrue(prompts.user.contains("Keep the original speech act intact."))
        XCTAssertTrue(prompts.user.contains("do not introduce new facts or remove meaningful details"))
    }

    // MARK: - transcriptionVocabularyHint with empty terms

    func testTranscriptionVocabularyHintWithEmptyTermsReturnsNil() {
        XCTAssertNil(PromptCatalog.transcriptionVocabularyHint(terms: []))
        XCTAssertNil(PromptCatalog.transcriptionVocabularyHint(terms: ["", "  "]))
    }

    // MARK: - automaticVocabularyDecisionPrompts

    func testAutomaticVocabularyDecisionPromptsGenerateCorrectContent() {
        let prompts = PromptCatalog.automaticVocabularyDecisionPrompts(
            transcript: "I love Typeflux app",
            oldFragment: "TypeFlux",
            newFragment: "Typeflux",
            candidateTerms: ["Typeflux"],
            existingTerms: ["GPT"],
        )

        XCTAssertTrue(prompts.system.contains("speech transcription vocabulary"))
        XCTAssertTrue(prompts.system.contains("{\"terms\":[\"term1\",\"term2\"]}"))
        XCTAssertTrue(prompts.system.contains("likely to mishear or misspell"))
        XCTAssertTrue(prompts.system.contains("Return at most 3 terms."))
        XCTAssertTrue(prompts.user.contains("<original_dictated_text>\nI love Typeflux app\n</original_dictated_text>"))
        XCTAssertTrue(prompts.user.contains("<previous_edited_fragment>\nTypeFlux\n</previous_edited_fragment>"))
        XCTAssertTrue(prompts.user.contains("<current_edited_fragment>\nTypeflux\n</current_edited_fragment>"))
        XCTAssertTrue(prompts.user.contains("<candidate_terms>\nTypeflux\n</candidate_terms>"))
        XCTAssertTrue(prompts.user.contains("<existing_vocabulary>\nGPT\n</existing_vocabulary>"))
    }

    func testAutomaticVocabularyDecisionPromptsHandleEmptyExistingTerms() {
        let prompts = PromptCatalog.automaticVocabularyDecisionPrompts(
            transcript: "test",
            oldFragment: "",
            newFragment: "fixed",
            candidateTerms: ["fixed"],
            existingTerms: [],
        )

        XCTAssertTrue(prompts.user.contains("<previous_edited_fragment>\n<empty>\n</previous_edited_fragment>"))
        XCTAssertTrue(prompts.user.contains("<existing_vocabulary>\n<empty>\n</existing_vocabulary>"))
    }

    func testAutomaticVocabularyDecisionPromptsUseXMLSectionsForInsertedContent() {
        let prompts = PromptCatalog.automaticVocabularyDecisionPrompts(
            transcript: "请打开 OpenAI Realtime API 文档",
            oldFragment: "Open AI",
            newFragment: "OpenAI Realtime API",
            candidateTerms: ["OpenAI Realtime API", "Realtime API"],
            existingTerms: ["SeedASR", "JSONSchema"],
        )

        XCTAssertTrue(prompts.user.contains("<original_dictated_text>\n请打开 OpenAI Realtime API 文档\n</original_dictated_text>"))
        XCTAssertTrue(prompts.user.contains("<previous_edited_fragment>\nOpen AI\n</previous_edited_fragment>"))
        XCTAssertTrue(prompts.user.contains("<current_edited_fragment>\nOpenAI Realtime API\n</current_edited_fragment>"))
        XCTAssertTrue(prompts.user.contains("<candidate_terms>\nOpenAI Realtime API, Realtime API\n</candidate_terms>"))
        XCTAssertTrue(prompts.user.contains("<existing_vocabulary>\nSeedASR, JSONSchema\n</existing_vocabulary>"))
    }
}

// MARK: - Extended PromptCatalog tests

extension PromptCatalogTests {
    // MARK: - xmlSection

    func testXmlSectionWithSimpleContent() {
        let result = PromptCatalog.xmlSection(tag: "text", content: "hello world")
        XCTAssertEqual(result, "<text>\nhello world\n</text>")
    }

    func testXmlSectionWithMultilineContent() {
        let result = PromptCatalog.xmlSection(tag: "context", content: "line 1\nline 2")
        XCTAssertTrue(result.hasPrefix("<context>"))
        XCTAssertTrue(result.hasSuffix("</context>"))
        XCTAssertTrue(result.contains("line 1"))
        XCTAssertTrue(result.contains("line 2"))
    }

    // MARK: - userEnvironmentContext

    func testUserEnvironmentContextIncludesDateAndLanguage() {
        let context = PromptCatalog.userEnvironmentContext(appLanguage: .english)
        XCTAssertFalse(context.isEmpty)
        // Should mention the language
        XCTAssertTrue(context.lowercased().contains("english") || context.contains("en"))
    }

    func testUserEnvironmentContextForChineseSimplified() {
        let context = PromptCatalog.userEnvironmentContext(appLanguage: .simplifiedChinese)
        XCTAssertFalse(context.isEmpty)
    }

    // MARK: - transcriptionVocabularyHint

    func testTranscriptionVocabularyHintWithValidTerms() throws {
        let hint = PromptCatalog.transcriptionVocabularyHint(terms: ["TypeFlux", "WhisperKit"])
        XCTAssertNotNil(hint)
        XCTAssertTrue(try XCTUnwrap(hint?.contains("TypeFlux")))
        XCTAssertTrue(try XCTUnwrap(hint?.contains("WhisperKit")))
    }

    func testTranscriptionVocabularyHintFiltersEmptyTerms() throws {
        let hint = PromptCatalog.transcriptionVocabularyHint(terms: ["", "   ", "ValidTerm"])
        XCTAssertNotNil(hint)
        XCTAssertTrue(try XCTUnwrap(hint?.contains("ValidTerm")))
    }

    func testTranscriptionVocabularyHintReturnsNilWhenAllTermsEmpty() {
        let hint = PromptCatalog.transcriptionVocabularyHint(terms: ["", "  "])
        XCTAssertNil(hint)
    }

    // MARK: - languageConsistencyRule

    func testLanguageConsistencyRuleIsNonEmpty() {
        let rule = PromptCatalog.languageConsistencyRule(for: "selected text")
        XCTAssertFalse(rule.isEmpty)
    }

    func testLanguageConsistencyRuleIncludesContentDescription() {
        let rule = PromptCatalog.languageConsistencyRule(for: "user's request")
        XCTAssertTrue(rule.contains("user's request"))
    }

    // MARK: - rewritePrompts

    func testRewritePromptsForRewriteTranscriptMode() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "hello world",
            spokenInstruction: nil,
            personaPrompt: "Be formal",
        )
        let prompts = PromptCatalog.rewritePrompts(for: request)
        XCTAssertFalse(prompts.system.isEmpty)
        XCTAssertFalse(prompts.user.isEmpty)
    }

    func testRewritePromptsSystemContainsPersonaWhenSet() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "test",
            spokenInstruction: nil,
            personaPrompt: "Use emoji",
        )
        let prompts = PromptCatalog.rewritePrompts(for: request)
        // In rewriteTranscript mode the persona goes into the user prompt, not the system prompt
        XCTAssertTrue(prompts.user.contains("Use emoji"))
    }

    func testRewritePromptsUserContainsSourceText() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "My voice transcript",
            spokenInstruction: nil,
            personaPrompt: nil,
        )
        let prompts = PromptCatalog.rewritePrompts(for: request)
        XCTAssertTrue(prompts.user.contains("My voice transcript"))
    }

    // MARK: - multimodalTranscriptionSystemPrompt

    func testMultimodalTranscriptionSystemPromptIncludesPersona() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: "Be very precise",
            vocabularyTerms: [],
        )
        XCTAssertTrue(prompt.contains("Be very precise"))
    }

    func testMultimodalTranscriptionSystemPromptWithVocabularyTerms() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: ["SwiftUI", "Combine"],
        )
        XCTAssertTrue(prompt.contains("SwiftUI"))
        XCTAssertTrue(prompt.contains("Combine"))
    }

    // MARK: - askAnythingPrompts

    func testAskAnythingPromptsWithSelectedTextAndInstruction() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: "Swift is a programming language",
            spokenInstruction: "Translate to Chinese",
            personaPrompt: nil,
            targetContext: PromptCatalog.AskTargetContext(editableTarget: true),
        )
        XCTAssertTrue(prompts.user.contains("Swift is a programming language"))
        XCTAssertTrue(prompts.user.contains("Translate to Chinese"))
    }

    func testAskAnythingPromptsSystemIsNonEmpty() {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: nil,
            spokenInstruction: "What is AI?",
            personaPrompt: nil,
            targetContext: PromptCatalog.AskTargetContext(editableTarget: false),
        )
        XCTAssertFalse(prompts.system.isEmpty)
    }

    // MARK: - AgentPromptCatalog

    func testAskAgentSystemPromptIncludesPersonaPrompt() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(
            personaPrompt: "Be concise and direct",
        )
        XCTAssertTrue(prompt.contains("Be concise and direct"))
    }

    func testAskAgentUserPromptWithSelectedText() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: "Hello world",
            instruction: "Translate to French",
        )
        XCTAssertTrue(prompt.contains("Hello world"))
        XCTAssertTrue(prompt.contains("Translate to French"))
    }

    func testAskAgentUserPromptWithoutSelectedText() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(selectedText: nil, instruction: "What is 2+2?")
        XCTAssertTrue(prompt.contains("What is 2+2?"))
        XCTAssertFalse(prompt.contains("Selected text:"))
    }

    func testAskAgentUserPromptWithEmptySelectedTextOmitsSection() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(selectedText: "   ", instruction: "Test")
        XCTAssertFalse(prompt.contains("Selected text:"))
    }
}
