import Foundation

// swiftlint:disable file_length function_body_length line_length
// swiftlint:disable:next type_body_length
enum PromptCatalog {
    private enum AskPromptMode {
        case decision
        case answer
    }

    struct AskTargetContext {
        let editableTarget: Bool?
    }

    private struct AskPromptContext {
        let selectedTextSection: String
        let spokenInstructionSection: String
        let targetContextSection: String

        var userContextBlock: String {
            [selectedTextSection, spokenInstructionSection, targetContextSection]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }

    static func languageConsistencyRule(for contentDescription: String, personaPrompt: String? = nil) -> String {
        if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            Language consistency rule:
            You must keep the output language consistent with the original language of the \(contentDescription) by default. Do not translate, paraphrase into another language, or switch languages because of persona defaults, vague style preferences, or formatting instructions alone. However, if <persona_definition> explicitly asks for translation or clearly specifies a target output language, treat that as a real language instruction and follow it unless a later instruction explicitly and clearly requires a different language.
            """
        }

        return """
        Language consistency rule:
        You must keep the output language consistent with the original language of the \(contentDescription) by default. Do not translate, paraphrase into another language, or switch languages because of persona defaults, style preferences, or formatting instructions alone. Only change the output language when a later instruction explicitly and clearly requires a different language.
        """
    }

    static func xmlSection(tag: String, content: String) -> String {
        """
        <\(tag)>
        \(content)
        </\(tag)>
        """
    }

    static func languageResolutionPolicy(appLanguage: AppLanguage) -> String {
        """
        Language resolution policy:
        - If a later user instruction explicitly requests a target language, follow that language.
        - If <persona_definition> explicitly asks for translation or clearly specifies a target output language, follow that requested language unless a later user instruction explicitly requires a different language.
        - Otherwise, when the task is editing, rewriting, or transcribing existing content and that source content has a clear language, preserve that language.
        - Otherwise, if <persona_definition> only suggests a language as a loose preference or style cue, do not let that override a clear source-language constraint.
        - Otherwise, default to the app interface language: \(appLanguage.promptDisplayName) (\(appLanguage.rawValue)).
        - Persona style or formatting instructions alone must not change the output language.
        - Proper nouns, product names, API names, code identifiers, and established technical terms may remain in their natural form when appropriate, but the surrounding text should still follow the resolved output language.
        This policy has higher priority than persona style preferences.
        """
    }

    static func userEnvironmentContext(
        preferredLanguages: [String] = Locale.preferredLanguages,
        appLanguage: AppLanguage,
    ) -> String {
        let systemLanguage = preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSystemLanguage = (systemLanguage?.isEmpty == false) ? systemLanguage! : "unknown"

        return """
        User environment context:
        - The user's operating system preferred language is: \(normalizedSystemLanguage)
        - The app interface language selected in settings is: \(appLanguage.rawValue)
        Treat this as supporting context only. Do not let it override explicit task instructions or source-language constraints.
        """
    }

    static func appendUserEnvironmentContext(
        to systemPrompt: String,
        preferredLanguages: [String] = Locale.preferredLanguages,
        appLanguage: AppLanguage,
    ) -> String {
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let languagePolicy = languageResolutionPolicy(appLanguage: appLanguage)
        let environmentContext = userEnvironmentContext(
            preferredLanguages: preferredLanguages,
            appLanguage: appLanguage,
        )

        guard !trimmedPrompt.isEmpty else { return "\(languagePolicy)\n\n\(environmentContext)" }
        return "\(languagePolicy)\n\n\(trimmedPrompt)\n\n\(environmentContext)"
    }

    /// Returns additional system prompt content tailored to the current app context.
    /// Called during system prompt assembly so that app-specific optimizations can be
    /// injected at the end of the system prompt. Currently injects a coding-context
    /// hint when the focused app is a code editor, IDE, or terminal emulator.
    /// - Parameter context: Environment info captured at the time of the LLM request.
    static func appSpecificSystemContext(_ context: AppSystemContext) -> String {
        NetworkDebugLogger.logMessage(
            """
            [AppSystemContext]
            bundleIdentifier: \(context.bundleIdentifier ?? "<nil>")
            appName: \(context.appName ?? "<nil>")
            role: \(context.role ?? "<nil>")
            windowTitle: \(context.windowTitle ?? "<nil>")
            isEditable: \(context.isEditable)
            isFocusedTarget: \(context.isFocusedTarget)
            selectedText(\(context.selectedText?.count ?? 0)): \(context.selectedText.map { String($0.prefix(80)) } ?? "<nil>")
            """,
        )

        if CodingAppDetector.isCodingApp(bundleIdentifier: context.bundleIdentifier) {
            return codingContextHint()
        }
        return ""
    }

    /// Hint block inserted when the user is dictating into a code editor, IDE, or
    /// terminal. Biases the model toward technical interpretations of ambiguous
    /// audio (programming terms, API names, literal identifiers, untranslated
    /// acronyms). Shared by multimodal transcription and LLM rewrite paths.
    static func codingContextHint() -> String {
        xmlSection(
            tag: "coding_context",
            content: """
            The user is dictating into a code editor, IDE, or terminal. When the audio is ambiguous, prefer a technical interpretation over an everyday-language guess:
            - Treat ambiguous words as programming terms, API names, library names, framework names, language keywords, or shell commands.
            - Preserve code identifiers verbatim in ASCII with their original casing, dots, underscores, brackets, and parentheses (e.g. "NSURLSession", "pgxpool", "bcrypt.CompareHashAndPassword", "snake_case", "CamelCase").
            - Keep English technical terms, function names, and library names in English even when the surrounding speech is in another language such as Chinese.
            - Do not expand acronyms such as "API", "JWT", "SDK", "ASR", "LLM", "OIDC" into their long form unless the speaker explicitly said the long form.
            - When the utterance sounds like a shell command, preserve flags, paths, and option syntax literally (e.g. "git commit -m", "./scripts/run.sh", "npm install --save-dev").
            """,
        )
    }

    /// Builds the system prompt for a multimodal LLM transcription call.
    /// When a persona is provided, the model transcribes AND rewrites in one shot.
    /// Otherwise, it acts as a high-quality transcription engine with vocabulary hints.
    /// When `bundleIdentifier` points at a code editor, IDE, or terminal, an additional
    /// coding-context hint is appended to bias the model toward technical interpretations.
    static func multimodalTranscriptionSystemPrompt(
        personaPrompt: String?,
        vocabularyTerms: [String],
        bundleIdentifier: String? = nil,
    ) -> String {
        let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasPersona = !persona.isEmpty
        let roleDefinition = hasPersona
            ? "You are a multimodal speech transcription and rewrite engine."
            : "You are a multimodal speech transcription engine."
        let taskInstruction = hasPersona
            ? """
            First transcribe the provided audio faithfully, then rewrite that transcript according to \
            <persona_definition> while preserving the original meaning, intent, and critical details.
            """
            : """
            Transcribe the provided audio faithfully and preserve the speaker's meaning, intent, wording, \
            and natural phrasing.
            """
        let outputContract = hasPersona
            ? """
            - Return only the final rewritten text.
            - Do not output the intermediate transcript.
            - Do not add explanations, labels, quotation marks, Markdown fences, or meta-commentary.
            """
            : """
            - Return only the final transcript text.
            - Do not add explanations, labels, quotation marks, Markdown fences, or meta-commentary.
            """
        let inputSemantics = hasPersona
            ? """
            - The audio payload is the only source content. It determines the transcript meaning and default output language.
            - <persona_definition> is style guidance for rewriting only. It is not source content and must not introduce new facts.
            - <vocabulary_hints> contains recognition hints only. Use these terms only when they are actually spoken in the audio.
            """
            : """
            - The audio payload is the only source content. It determines the transcript meaning and default output language.
            - <vocabulary_hints> contains recognition hints only. Use these terms only when they are actually spoken in the audio.
            """
        let ruleBlock = xmlSection(
            tag: "rules",
            content: """
            <language_policy>
            \(languageConsistencyRule(for: "spoken content", personaPrompt: personaPrompt))
            </language_policy>
            <input_semantics>
            \(inputSemantics)
            </input_semantics>
            <task_procedure>
            \(taskInstruction)
            </task_procedure>
            <fidelity_requirements>
            - Preserve all critical information from the speech, including names, numbers, dates, times, places, negations, requests, decisions, and action items.
            - Do not compress, generalize, or omit specific details just to sound cleaner or shorter.
            - Preserve the speaker's speech act: if the user sounds like they are asking, instructing, reminding,
              confirming, correcting, or drafting a message, keep that intent explicit in the final text.
            - For very short or fragmentary utterances, prefer a complete and faithful rendering of the likely intent
              over an overly terse rewrite.
            - You may fix obvious recognition errors, punctuation, and casing, and you may add only the minimal
              connecting words needed to make a brief utterance usable, but do not add new facts, requests, or
              context.
            - When persona style conflicts with completeness or fidelity, preserve completeness and fidelity first.
            </fidelity_requirements>
            <output_contract>
            \(outputContract)
            </output_contract>
            """,
        )

        var parts: [String] = [roleDefinition, ruleBlock]

        if hasPersona {
            parts.append(xmlSection(tag: "persona_definition", content: persona))
        }

        if let hint = transcriptionVocabularyHint(terms: vocabularyTerms) {
            parts.append(hint)
        }

        if CodingAppDetector.isCodingApp(bundleIdentifier: bundleIdentifier) {
            parts.append(codingContextHint())
        }

        return parts.joined(separator: "\n\n")
    }

    static func transcriptionVocabularyHint(terms: [String]) -> String? {
        let normalizedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedTerms.isEmpty else { return nil }

        return xmlSection(
            tag: "vocabulary_hints",
            content: """
            <instruction>
            Recognize these words and phrases accurately, preserving their spelling and casing when possible. Do not emit any term unless it is actually spoken in the audio.
            </instruction>
            <terms>
            \(normalizedTerms.joined(separator: ", "))
            </terms>
            """,
        )
    }

    static func rewritePrompts(for request: LLMRewriteRequest) -> (system: String, user: String) {
        switch request.mode {
        case .editSelection:
            let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceTextRule = languageConsistencyRule(for: "selected text", personaPrompt: request.personaPrompt)
            let sourceSection = xmlSection(tag: "selected_text", content: request.sourceText)
            let instructionSection = xmlSection(tag: "spoken_instruction", content: spokenInstruction)
            let inputContextSection = inputContextSection(for: request.inputContext)
            let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outputRequirement = if !personaPrompt.isEmpty {
                """

                <output_requirements>
                - Treat the spoken instruction as the highest-priority requirement.
                - Apply the persona definition only when it does not conflict with the edit intent.
                </output_requirements>

                <persona_definition>
                \(personaPrompt)
                </persona_definition>
                """
            } else {
                """

                <output_requirements>
                - Treat the spoken instruction as the highest-priority requirement.
                </output_requirements>
                """
            }

            return (
                system: """
                You are a text editing assistant. When editing existing text, preserve the user's editing intent first and use any persona requirement only as a secondary output-style constraint. Return only the final rewritten text without explanations or quotation marks.

                User prompt structure:
                - "<selected_text>" is the source content to edit.
                - "<spoken_instruction>" is the user's edit intent and has the highest priority.
                - "<input_context>" is optional nearby text from the active input field. Use it only to understand local context; do not copy, summarize, or disclose it unless the user explicitly asked for that content.
                - "<output_requirements>" contains system-authored processing rules, including how persona constraints should be applied.
                - "<persona_definition>" is a style constraint, not source content.
                """,
                user: """
                \(sourceSection)

                \(instructionSection)\(inputContextSection)\(outputRequirement)

                \(sourceTextRule)

                Return only the final rewritten text.
                """,
            )

        case .rewriteTranscript:
            let sourceTextRule = languageConsistencyRule(for: "source text", personaPrompt: request.personaPrompt)
            let transcriptSection = xmlSection(tag: "raw_transcript", content: request.sourceText)
            let inputContextSection = inputContextSection(for: request.inputContext)
            let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let personaSection = personaPrompt.isEmpty ? "" : """

            \(xmlSection(tag: "persona_definition", content: personaPrompt))
            """
            return (
                system: """
                You rewrite dictated text into polished final copy. Treat the transcript as source content that may \
                contain recognition noise, but preserve the user's full intent and every critical detail. Follow the \
                persona requirements exactly when provided, unless they would cause information loss or change the \
                user's meaning. Return only the final text without explanations or quotation marks.

                User prompt structure:
                - "<raw_transcript>" is the source content to rewrite.
                - "<input_context>" is optional nearby text from the active input field. Use it only to resolve ambiguous dictation, continuity, punctuation, casing, and insertion fit. Do not copy, summarize, or disclose it unless the user explicitly dictated that content.
                - "<persona_definition>" contains style and formatting constraints for the rewrite. It is not source content.
                """,
                user: """
                \(transcriptSection)\(inputContextSection)\(personaSection)

                \(sourceTextRule)

                Rewrite requirements:
                - Preserve all critical information, including names, numbers, dates, times, negations, commitments, requests, and action items.
                - Keep the original speech act intact. Questions should stay questions, requests should stay requests, and draft messages should remain usable as messages.
                - For very short transcripts, be especially careful not to over-compress. If needed, add only the \
                  minimal wording required to make the intent complete and clear.
                - Clean up recognition artifacts, punctuation, casing, and obvious filler if needed, but do not introduce new facts or remove meaningful details.

                Return only the final text.
                """,
            )
        }
    }

    private static func inputContextSection(for context: InputContextSnapshot?) -> String {
        guard let context, context.hasContent else { return "" }

        var lines: [String] = []
        if let appName = context.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            lines.append("App: \(appName)")
        }
        if let role = context.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            lines.append("Focused role: \(role)")
        }
        lines.append("Editable target: \(context.isEditable ? "yes" : "no")")
        lines.append("Focused target: \(context.isFocusedTarget ? "yes" : "no")")
        if !context.prefix.isEmpty {
            lines.append("Text before cursor:\n\(context.prefix)")
        }
        if let selectedText = context.selectedText, !selectedText.isEmpty {
            lines.append("Selected text:\n\(selectedText)")
        }
        if !context.suffix.isEmpty {
            lines.append("Text after cursor:\n\(context.suffix)")
        }

        return "\n\n" + xmlSection(
            tag: "input_context",
            content: lines.joined(separator: "\n\n"),
        )
    }

    static func automaticVocabularyDecisionPrompts(
        transcript: String,
        oldFragment: String,
        newFragment: String,
        candidateTerms: [String],
        existingTerms: [String],
    ) -> (system: String, user: String) {
        let existingSummary = existingTerms.isEmpty ? "<empty>" : existingTerms.joined(separator: ", ")
        let oldSummary = oldFragment.isEmpty ? "<empty>" : oldFragment
        let candidateSummary = candidateTerms.joined(separator: ", ")

        return (
            system: """
            You decide whether user-corrected terms should be added to a speech transcription vocabulary.
            Your goal is to keep entries that are likely to improve future speech recognition accuracy.
            Prefer keeping any correction that looks like one of these:
            1. A word or short phrase that speech recognition is likely to mishear or misspell (capitalization fixes, spacing fixes, homophones, brand spellings all qualify).
            2. A professional term, product name, model name, framework name, API name, protocol name, command, code identifier, or other domain-specific term.
            When the correction spans two or more tokens (e.g. "Open AI" → "OpenAI", "read me" → "readme"), keep the corrected form — those are exactly the mistakes an ASR vocabulary fixes.
            Reject only clear non-terms:
            - common everyday words with no correction value
            - filler words or conversational fragments
            - punctuation-only changes
            - pure grammar fixes with no new terminology
            - complete clauses or sentence fragments copied from the transcript
            - content added only to clarify meaning, tone, or context
            A valid vocabulary entry must be short and term-like:
            - usually 1 term or a very short phrase
            - not a full sentence
            - not a large text span
            - not more than 3 English words
            - not more than 8 Chinese characters unless it is clearly a fixed technical term
            Minimum length requirements (reject anything shorter):
            - English / Latin / alphanumeric terms must be at least 3 characters and contain letters (e.g. "GPT", "API", "LLM", "iOS", "Rust" OK; "AI", "UI", "Go", "123", "X" rejected).
            - Chinese terms must contain at least 2 Han characters (e.g. "向量", "推理" OK; single-character terms rejected).
            - Mixed terms containing any Han character must still be at least 2 characters total.
            Good examples:
            - PRDPlus
            - SeedASR
            - OpenAI Realtime API
            - JSONSchema
            - 向量数据库
            - 声纹识别
            Bad examples:
            - 我刚刚的意思是
            - 这个方案也可以
            - 请帮我改一下
            - today afternoon meeting
            - let me explain this
            - a whole sentence copied from the transcript
            When in doubt about a candidate that looks like a real term/name/acronym, keep it — duplicates and noise are inexpensive to prune later; missing a real domain term hurts recognition quality.
            Return strict JSON only in the form {"terms":["term1","term2"]}.
            Return at most 3 terms.
            If nothing qualifies, return {"terms":[]}.
            Never wrap the JSON in Markdown code fences.
            Never include commentary, explanation, or any keys other than "terms".
            """,
            user: """
            \(xmlSection(tag: "original_dictated_text", content: transcript))

            \(xmlSection(tag: "previous_edited_fragment", content: oldSummary))

            \(xmlSection(tag: "current_edited_fragment", content: newFragment))

            \(xmlSection(tag: "candidate_terms", content: candidateSummary))

            \(xmlSection(tag: "existing_vocabulary", content: existingSummary))

            Keep the candidates that look like real domain terms, product/model/framework/API names, code identifiers, or spacing/capitalization corrections that speech recognition is likely to mishear.
            Lean toward keeping genuine term-like corrections; reject only obvious non-terms per the system guidance.
            Return strict JSON only.
            """,
        )
    }

    static func askSelectionDecisionPrompts(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt _: String?,
        editableTarget: Bool?,
    ) -> (system: String, user: String) {
        let context = buildAskPromptContext(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            targetContext: AskTargetContext(editableTarget: editableTarget),
        )

        return (
            system: sharedAskSystemPrompt(mode: .decision),
            user: """
            \(context.userContextBlock)

            Decision guidance:
            - Questions like "what does this mean", "explain this", "is this correct", "what's wrong here", or "summarize what this says" are usually "answer".
            - Commands like "rewrite this", "translate this", "make this shorter", "fix the grammar", "turn this into bullet points", or "change the tone" are usually "edit".
            - Imperative requests to produce replacement text, such as "help me write this", "help me improve this", "帮我写一下", "帮我改一下", or "帮我润色一下", should be treated as "edit" when the selected text is the thing to change.
            - If the target is not editable, still help the user by returning the best read-only answer or rewritten result in "content", but keep "answer_edit" set to "answer".

            If you choose "answer", provide the final answer in "content".
            If you choose "edit", provide the final rewritten text in "content".
            """,
        )
    }

    static func askAnythingPrompts(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt _: String?,
        targetContext: AskTargetContext,
    ) -> (system: String, user: String) {
        let context = buildAskPromptContext(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            targetContext: targetContext,
        )

        return (
            system: sharedAskSystemPrompt(mode: .answer),
            user: """
            \(context.userContextBlock)

            Answer the user's request directly.
            If the user is effectively asking you to draft, rewrite, polish, or improve text, provide that final text directly.
            Use Markdown formatting when it improves readability.
            """,
        )
    }

    private static func buildAskPromptContext(
        selectedText: String?,
        spokenInstruction: String,
        targetContext: AskTargetContext,
    ) -> AskPromptContext {
        let normalizedSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedTextSection = normalizedSelectedText.isEmpty ? "" : xmlSection(tag: "selected_text", content: normalizedSelectedText)
        let spokenInstructionSection = xmlSection(
            tag: "spoken_instruction",
            content: spokenInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        let targetContextSection: String = if let editableTarget = targetContext.editableTarget {
            xmlSection(
                tag: "target_context",
                content: """
                <editable_target>\(editableTarget ? "true" : "false")</editable_target>
                """,
            )
        } else {
            ""
        }

        return AskPromptContext(
            selectedTextSection: selectedTextSection,
            spokenInstructionSection: spokenInstructionSection,
            targetContextSection: targetContextSection,
        )
    }

    private static func askIntentInterpretationGuidance(editableTargetAware: Bool) -> String {
        var rules = [
            "Interpret imperative writing or rewriting instructions as requests for final output, not as meta-questions about how to write.",
            "Treat requests like \"help me write this\", \"help me rewrite this\", \"help me polish this\", \"help me improve this\", \"帮我写\", \"帮我改\", or \"帮我润色\" as direct requests to produce improved text when they target the selected text itself.",
        ]

        if editableTargetAware {
            rules.insert(
                "If <editable_target> is false, you must choose \"answer\" even if the user asked for a rewrite. In that case, return a read-only result in \"content\" instead of an edit action.",
                at: 0,
            )
            rules.insert(
                "If <editable_target> is true and the user gives an imperative writing or rewriting instruction, prefer \"edit\" even when the instruction is phrased conversationally instead of as a strict command.",
                at: 1,
            )
        }

        return rules.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func sharedAskSystemPrompt(mode: AskPromptMode) -> String {
        let sharedGuidance = askIntentInterpretationGuidance(editableTargetAware: true)

        switch mode {
        case .decision:
            return """
            You handle single-shot "Ask Anything" requests about selected text.

            You must choose exactly one value for "answer_edit":
            - "answer": The user is asking a question, requesting explanation, analysis, clarification, extraction of information, or any other read-only help. When you choose "answer", provide the final answer in the "content" field.
            - "edit": The user explicitly wants the selected text itself to be transformed and written back, such as rewriting, translating, shortening, expanding, fixing, reformatting, or changing tone. When you choose "edit", provide the final rewritten text in the "content" field.

            Stability rules:
            - Default to "answer" whenever the intent is ambiguous.
            - Never choose "edit" unless the user clearly wants to replace the selected text.
            \(sharedGuidance)
            - When you choose "edit", return the completed replacement text directly. Do not describe the edit.
            - When you choose "answer", return the completed answer directly. Do not describe your decision.
            - You must respond by calling the provided tool.
            """
        case .answer:
            return """
            You answer spoken "Ask Anything" requests.

            Provide a direct, helpful answer to the user's spoken question or request.
            If selected text is provided, treat it as the user's current context and use it when answering.
            \(sharedGuidance)
            If the request is ambiguous, make the most reasonable interpretation and answer that.
            Format the answer as clean Markdown whenever structure would help, using headings, bullet lists, numbered lists, blockquotes, and paragraphs as appropriate.
            Preserve real Markdown line breaks. Do not collapse the answer into one paragraph when the content is structured.
            Return only the final answer text without JSON, code fences, or meta-commentary about your process.
            """
        }
    }
}

// swiftlint:enable file_length function_body_length line_length
