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

    func testLanguageConsistencyRuleTreatsPersonaTranslationRequestAsLanguageInstruction() {
        let rule = PromptCatalog.languageConsistencyRule(
            for: "source text",
            personaPrompt: """
            将内容翻译为地地道道的中文。
            """,
        )

        XCTAssertTrue(rule.contains("explicitly asks for translation"))
        XCTAssertTrue(rule.contains("treat that as a real language instruction"))
    }

    func testAppendUserEnvironmentContextAddsSystemAndAppLanguageToSystemPrompt() {
        let prompt = PromptCatalog.appendUserEnvironmentContext(
            to: "Base system prompt.",
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            appLanguage: .english,
        )

        XCTAssertTrue(prompt.hasPrefix("Language resolution policy:"))
        XCTAssertTrue(prompt.contains("default to the app interface language: English (en)"))
        XCTAssertTrue(prompt.contains("explicitly asks for translation"))
        XCTAssertTrue(prompt.contains("Base system prompt."))
        XCTAssertTrue(prompt.contains("User environment context:"))
        XCTAssertTrue(prompt.contains("The user's operating system preferred language is: zh-Hans-CN"))
        XCTAssertTrue(prompt.contains("The app interface language selected in settings is: en"))
        XCTAssertTrue(prompt.contains("Treat this as supporting context only. Do not let it override explicit task instructions or source-language constraints."))
        XCTAssertTrue(prompt.range(of: "User environment context:")!.lowerBound < prompt.range(of: "Base system prompt.")!.lowerBound)
    }

    func testLanguageResolutionPolicyUsesAppLanguageFallbackAndPersonaPriorityRules() {
        let policy = PromptCatalog.languageResolutionPolicy(appLanguage: .simplifiedChinese)

        XCTAssertTrue(policy.contains("If a later user instruction explicitly requests a target language"))
        XCTAssertTrue(policy.contains("If <persona_definition> explicitly asks for translation"))
        XCTAssertTrue(policy.contains("Otherwise, default to the app interface language: Simplified Chinese (zh-Hans)."))
        XCTAssertTrue(policy.contains("Persona style or formatting instructions alone must not change the output language."))
    }

    func testAppendAdditionalSystemContextKeepsOutputContractLast() {
        let prompt = """
        You convert dictated speech into directly usable text.

        INPUT STRUCTURE
        - <raw_transcript> is the source content to process.

        OUTPUT
        Return only the final processed text.
        No explanations.
        """

        let result = PromptCatalog.appendAdditionalSystemContext(
            "<coding_context>\nPrefer technical terms.\n</coding_context>",
            to: prompt,
        )

        XCTAssertTrue(result.contains("<coding_context>\nPrefer technical terms.\n</coding_context>\n\nOUTPUT"))
        XCTAssertTrue(result.hasSuffix("""
        OUTPUT
        Return only the final processed text.
        No explanations.
        """))
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

        XCTAssertTrue(prompts.system.contains("You convert dictated speech into directly usable text."))
        XCTAssertTrue(prompts.system.contains("PRIMARY OBJECTIVE"))
        XCTAssertTrue(prompts.system.contains("INSTRUCTION PRIORITY"))
        XCTAssertTrue(prompts.system.contains("PERSONA HANDLING"))
        XCTAssertTrue(prompts.system.contains("persona_definition is an active instruction, not source content."))
        XCTAssertTrue(prompts.system.contains("- <raw_transcript> is the source content to process. It may contain speech-recognition errors."))
        XCTAssertFalse(prompts.system.contains(PromptCatalog.languageConsistencyRule(for: "source text")))
        XCTAssertTrue(prompts.user.contains("<raw_transcript>\nraw text\n</raw_transcript>"))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\nformal and concise\n</persona_definition>"))
        XCTAssertTrue(prompts.user.contains("Process <raw_transcript> according to the system prompt."))
    }

    func testRewritePromptsAllowPersonaTranslationInstructionToOverrideSourceLanguage() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "你好，世界",
            spokenInstruction: nil,
            personaPrompt: """
            将内容翻译为地地道道的中文。
            """,
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("If persona_definition explicitly requests translation or specifies a target output language, follow it."))
        XCTAssertTrue(prompts.system.contains("- Otherwise, if persona_definition explicitly specifies a target output language or translation task, use that language."))
        XCTAssertTrue(prompts.user.contains("<persona_definition>\n将内容翻译为地地道道的中文。\n</persona_definition>"))
    }

    func testRewriteTranscriptPromptIncludesVocabularyHintsWhenProvided() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "请把这个 seed asr 的配置打开",
            spokenInstruction: nil,
            personaPrompt: nil,
            vocabularyTerms: ["SeedASR", "Typeflux"],
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertTrue(prompts.system.contains("<vocabulary_hints> is an optional user vocabulary list"))
        XCTAssertTrue(prompts.system.contains("Use it only to correct likely speech-recognition errors or ambiguities"))
        XCTAssertTrue(prompts.user.contains("<vocabulary_hints>"))
        XCTAssertTrue(prompts.user.contains("These are user vocabulary terms that speech recognition often mishears"))
        XCTAssertTrue(prompts.user.contains("<terms>\nSeedASR, Typeflux\n</terms>"))
    }

    func testRewriteTranscriptPromptOmitsVocabularyHintsWhenEmpty() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "hello world",
            spokenInstruction: nil,
            personaPrompt: nil,
            vocabularyTerms: [],
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)

        XCTAssertFalse(prompts.user.contains("<vocabulary_hints>"))
    }

    func testRewritePromptDebugDescriptionShowsFinalAssembledPrompt() {
        let inputContext = InputContextSnapshot(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            isEditable: true,
            isFocusedTarget: true,
            prefix: "这个新版本整体体验我试了下，",
            suffix: "你可以也体验一下。",
            selectedText: nil,
        )
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "效果很不错吧。",
            spokenInstruction: nil,
            personaPrompt: """
            任务：将用户的中文口述内容翻译并整理成自然的英文表达。

            要求：
            - 输出英文
            - 保持原意
            - 表达自然、简洁
            - 不要添加用户没有表达的新信息
            """,
            inputContext: inputContext,
            vocabularyTerms: ["Typeflux", "SeedASR"],
        )

        let prompts = PromptCatalog.rewritePrompts(for: request)
        let finalSystemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: prompts.system,
            preferredLanguages: ["zh-Hans-CN"],
            appLanguage: .english,
        )
        let debugPrompt = PromptCatalog.rewritePromptDebugDescription(
            system: finalSystemPrompt,
            user: prompts.user,
        )

        XCTAssertTrue(debugPrompt.hasPrefix("[Rewrite Prompt]\nSystem:\nYou convert dictated speech into directly usable text."))
        XCTAssertTrue(debugPrompt.contains("You convert dictated speech into directly usable text."))
        XCTAssertTrue(debugPrompt.contains("PRIMARY OBJECTIVE\nPreserve the user's intended meaning while applying the user's persona instructions."))
        XCTAssertTrue(debugPrompt.contains("INSTRUCTION PRIORITY\n1. Follow explicit user instructions in the current request."))
        XCTAssertTrue(debugPrompt.contains("PERSONA HANDLING\npersona_definition is an active instruction, not source content."))
        XCTAssertTrue(debugPrompt.contains("LANGUAGE\nLanguage resolution policy:"))
        XCTAssertTrue(debugPrompt.contains("User environment context:"))
        XCTAssertFalse(debugPrompt.contains("LANGUAGE\n- If the current user request explicitly specifies a target language, use that language."))
        XCTAssertTrue(debugPrompt.contains("SHORT UTTERANCE RULE\nIf the transcript is short and already complete, keep it close to the original"))
        XCTAssertTrue(debugPrompt.contains("INPUT CONTEXT\ninput_context may contain nearby user text from the active field."))
        XCTAssertTrue(debugPrompt.contains("OUTPUT\nReturn only the final processed text."))
        XCTAssertTrue(debugPrompt.contains("User:\n<raw_transcript>\n效果很不错吧。\n</raw_transcript>"))
        XCTAssertTrue(debugPrompt.contains("<input_context>"))
        XCTAssertTrue(debugPrompt.contains("<text_before_cursor><![CDATA[\n这个新版本整体体验我试了下，\n]]></text_before_cursor>"))
        XCTAssertTrue(debugPrompt.contains("<cursor />"))
        XCTAssertTrue(debugPrompt.contains("<text_after_cursor><![CDATA[\n你可以也体验一下。\n]]></text_after_cursor>"))
        XCTAssertTrue(debugPrompt.contains("<vocabulary_hints>"))
        XCTAssertTrue(debugPrompt.contains("<terms>\nTypeflux, SeedASR\n</terms>"))
        XCTAssertTrue(debugPrompt.contains("<persona_definition>\n任务：将用户的中文口述内容翻译并整理成自然的英文表达。"))
        XCTAssertTrue(debugPrompt.contains("- 输出英文"))
        XCTAssertTrue(debugPrompt.contains("Process <raw_transcript> according to the system prompt."))
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
        XCTAssertTrue(prompts.user.contains(PromptCatalog.languageConsistencyRule(
            for: "selected text",
            personaPrompt: "professional but warm",
        )))
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

    func testMultimodalTranscriptionPromptIncludesDictationRewriteFramework() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: "Use concise business language.",
            vocabularyTerms: ["Typeflux"],
        )

        XCTAssertTrue(prompt.contains("You convert dictated speech into directly usable text."))
        XCTAssertTrue(prompt.contains("PRIMARY OBJECTIVE"))
        XCTAssertTrue(prompt.contains("LANGUAGE"))
        XCTAssertTrue(prompt.contains("- If the current user request explicitly specifies a target language, use that language."))
        XCTAssertTrue(prompt.contains("SHORT UTTERANCE RULE"))
        XCTAssertTrue(prompt.contains("If the transcript is short and already complete, keep it close to the original"))
        XCTAssertTrue(prompt.contains("- The audio payload is the user's dictated speech and the only source content."))
        XCTAssertTrue(prompt.contains("- First infer the faithful raw transcript from the audio, then process that transcript according to this prompt."))
        XCTAssertTrue(prompt.contains("<persona_definition>\nUse concise business language.\n</persona_definition>"))
        XCTAssertTrue(prompt.contains("<vocabulary_hints>"))
        XCTAssertTrue(prompt.contains("<terms>\nTypeflux\n</terms>"))
        XCTAssertTrue(prompt.contains("Do not output the intermediate transcript."))
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

        XCTAssertTrue(result.hasPrefix("Language resolution policy:"))
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

        XCTAssertTrue(prompts.system.contains("Preserve the source meaning, critical details, and speech act."))
        XCTAssertTrue(prompts.system.contains("Do not add facts, invent details, summarize away meaning, or strengthen tone beyond the user's intent."))
        XCTAssertTrue(prompts.system.contains("Questions remain questions unless persona_definition explicitly transforms the content into another format."))
        XCTAssertTrue(prompts.system.contains("Requests remain requests unless persona_definition explicitly transforms the content into another format."))
        XCTAssertTrue(prompts.system.contains("If the transcript is short and already complete, keep it close to the original unless persona_definition requires translation, reformatting, or a specific style transformation."))
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
        let prompt = AgentPromptCatalog.routerSystemPrompt(
            personaPrompt: "Be concise and direct",
        )
        XCTAssertTrue(prompt.contains("Be concise and direct"))
    }

    func testAskAgentUserPromptWithSelectedText() {
        let prompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: "Hello world",
            instruction: "Translate to French",
        )
        XCTAssertTrue(prompt.contains("Hello world"))
        XCTAssertTrue(prompt.contains("Translate to French"))
    }

    func testAskAgentUserPromptWithoutSelectedText() {
        let prompt = AgentPromptCatalog.routerUserPrompt(selectedText: nil, instruction: "What is 2+2?")
        XCTAssertTrue(prompt.contains("What is 2+2?"))
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }

    func testAskAgentUserPromptWithEmptySelectedTextOmitsSection() {
        let prompt = AgentPromptCatalog.routerUserPrompt(selectedText: "   ", instruction: "Test")
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }

    // MARK: - codingContextHint

    func testCodingContextHintWrapsInCodingContextTag() {
        let hint = PromptCatalog.codingContextHint()

        XCTAssertTrue(hint.hasPrefix("<coding_context>"))
        XCTAssertTrue(hint.hasSuffix("</coding_context>"))
        XCTAssertTrue(hint.contains("code editor, IDE, or terminal"))
        XCTAssertTrue(hint.contains("Preserve code identifiers verbatim"))
        XCTAssertTrue(hint.contains("snake_case"))
        XCTAssertTrue(hint.contains("CamelCase"))
        XCTAssertTrue(hint.contains("Do not expand acronyms"))
        XCTAssertTrue(hint.contains("shell command"))
    }

    // MARK: - appSpecificSystemContext

    func testAppSpecificSystemContextInjectsCodingHintForCodingApps() {
        let context = AppSystemContext(snapshot: makeSnapshot(bundleIdentifier: "com.apple.dt.Xcode"))

        let result = PromptCatalog.appSpecificSystemContext(context)

        XCTAssertEqual(result, PromptCatalog.codingContextHint())
    }

    func testAppSpecificSystemContextInjectsCodingHintForJetBrainsApp() {
        let context = AppSystemContext(snapshot: makeSnapshot(bundleIdentifier: "com.jetbrains.goland"))

        let result = PromptCatalog.appSpecificSystemContext(context)

        XCTAssertTrue(result.contains("<coding_context>"))
    }

    func testAppSpecificSystemContextReturnsEmptyForNonCodingApp() {
        let context = AppSystemContext(snapshot: makeSnapshot(bundleIdentifier: "com.apple.Safari"))

        let result = PromptCatalog.appSpecificSystemContext(context)

        XCTAssertEqual(result, "")
    }

    func testAppSpecificSystemContextReturnsEmptyWhenBundleIdentifierMissing() {
        let context = AppSystemContext(snapshot: makeSnapshot(bundleIdentifier: nil))

        let result = PromptCatalog.appSpecificSystemContext(context)

        XCTAssertEqual(result, "")
    }

    // MARK: - multimodalTranscriptionSystemPrompt (coding-context awareness)

    func testMultimodalTranscriptionSystemPromptAppendsCodingContextForCodingApps() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: [],
            bundleIdentifier: "com.microsoft.VSCode",
        )

        XCTAssertTrue(prompt.contains("<coding_context>"))
        XCTAssertTrue(prompt.contains("Preserve code identifiers verbatim"))
    }

    func testMultimodalTranscriptionSystemPromptOmitsCodingContextForNonCodingApps() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: [],
            bundleIdentifier: "com.apple.Safari",
        )

        XCTAssertFalse(prompt.contains("<coding_context>"))
    }

    func testMultimodalTranscriptionSystemPromptOmitsCodingContextWhenBundleIdentifierMissing() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: [],
        )

        XCTAssertFalse(prompt.contains("<coding_context>"))
    }

    func testMultimodalTranscriptionSystemPromptAppendsCodingContextAfterVocabularyHint() {
        let prompt = PromptCatalog.multimodalTranscriptionSystemPrompt(
            personaPrompt: nil,
            vocabularyTerms: ["pgxpool"],
            bundleIdentifier: "com.apple.dt.Xcode",
        )

        guard let vocabularyRange = prompt.range(of: "<vocabulary_hints>"),
              let codingRange = prompt.range(of: "<coding_context>")
        else {
            XCTFail("Both hint blocks should be present")
            return
        }

        XCTAssertTrue(vocabularyRange.lowerBound < codingRange.lowerBound)
    }

    // MARK: - Helpers

    private func makeSnapshot(bundleIdentifier: String?) -> TextSelectionSnapshot {
        var snapshot = TextSelectionSnapshot()
        snapshot.bundleIdentifier = bundleIdentifier
        snapshot.processName = "TestApp"
        snapshot.isFocusedTarget = true
        return snapshot
    }
}
