import Foundation

enum PromptCatalog {
    static func languageConsistencyRule(for contentDescription: String) -> String {
        """
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

    static func userEnvironmentContext(
        preferredLanguages: [String] = Locale.preferredLanguages,
        appLanguage: AppLanguage
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
        appLanguage: AppLanguage
    ) -> String {
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentContext = userEnvironmentContext(
            preferredLanguages: preferredLanguages,
            appLanguage: appLanguage
        )

        guard !trimmedPrompt.isEmpty else { return environmentContext }
        return "\(trimmedPrompt)\n\n\(environmentContext)"
    }

    /// Builds the system prompt for a multimodal LLM transcription call.
    /// When a persona is provided, the model transcribes AND rewrites in one shot.
    /// Otherwise, it acts as a high-quality transcription engine with vocabulary hints.
    static func multimodalTranscriptionSystemPrompt(personaPrompt: String?, vocabularyTerms: [String]) -> String {
        var parts: [String] = []
        let spokenContentRule = languageConsistencyRule(for: "spoken content")

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !persona.isEmpty {
            parts.append("""
            \(spokenContentRule)

            You are a transcription and text-rewriting assistant.
            Transcribe the audio accurately, then immediately rewrite the result according to the persona requirements below.
            Return only the final rewritten text — no explanations, no quotation marks, no meta-commentary.

            Input semantics:
            - The audio is the source content that determines the default output language and meaning.
            - Persona requirements are style constraints for the final rewrite. They are not source content.
            - Vocabulary hints are recognition hints only. They are not source content and must not be copied unless spoken.

            Persona requirements:
            \(persona)
            """)
        } else {
            parts.append("""
            \(spokenContentRule)

            You are a precise transcription assistant.
            Transcribe the audio accurately. Preserve the speaker's intent and natural phrasing.
            Return only the transcribed text — no explanations, no meta-commentary.

            Input semantics:
            - The audio is the source content that determines the output language and meaning.
            - Vocabulary hints are recognition hints only. They are not source content and must not be copied unless spoken.
            """)
        }

        if let hint = transcriptionVocabularyHint(terms: vocabularyTerms) {
            parts.append(hint)
        }

        return parts.joined(separator: "\n\n")
    }

    static func transcriptionVocabularyHint(terms: [String]) -> String? {
        let normalizedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedTerms.isEmpty else { return nil }

        return """
        Recognize these words and phrases accurately, preserving their spelling and casing when possible:
        \(normalizedTerms.joined(separator: ", "))
        """
    }

    static func rewritePrompts(for request: LLMRewriteRequest) -> (system: String, user: String) {
        switch request.mode {
        case .editSelection:
            let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceTextRule = languageConsistencyRule(for: "selected text")
            let sourceSection = xmlSection(tag: "selected_text", content: request.sourceText)
            let instructionSection = xmlSection(tag: "spoken_instruction", content: spokenInstruction)
            let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outputRequirement: String
            if !personaPrompt.isEmpty {
                outputRequirement = """

                <output_requirements>
                - Treat the spoken instruction as the highest-priority requirement.
                - Apply the persona definition only when it does not conflict with the edit intent.
                </output_requirements>

                <persona_definition>
                \(personaPrompt)
                </persona_definition>
                """
            } else {
                outputRequirement = """

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
                - "<output_requirements>" contains system-authored processing rules, including how persona constraints should be applied.
                - "<persona_definition>" is a style constraint, not source content.
                """,
                user: """
                \(sourceSection)

                \(instructionSection)\(outputRequirement)

                \(sourceTextRule)

                Return only the final rewritten text.
                """
            )

        case .rewriteTranscript:
            let sourceTextRule = languageConsistencyRule(for: "source text")
            let transcriptSection = xmlSection(tag: "raw_transcript", content: request.sourceText)
            let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let personaSection = personaPrompt.isEmpty ? "" : """

            \(xmlSection(tag: "persona_definition", content: personaPrompt))
            """
            return (
                system: """
                You rewrite dictated text into polished final copy. Follow the persona requirements exactly when provided. Return only the final text without explanations or quotation marks.

                User prompt structure:
                - "<raw_transcript>" is the source content to rewrite.
                - "<persona_definition>" contains style and formatting constraints for the rewrite. It is not source content.
                """,
                user: """
                \(transcriptSection)\(personaSection)

                \(sourceTextRule)

                Clean up recognition artifacts if needed and return only the final text.
                """
            )
        }
    }

    static func automaticVocabularyDecisionPrompts(
        transcript: String,
        oldFragment: String,
        newFragment: String,
        candidateTerms: [String],
        existingTerms: [String]
    ) -> (system: String, user: String) {
        let existingSummary = existingTerms.isEmpty ? "<empty>" : existingTerms.joined(separator: ", ")
        let oldSummary = oldFragment.isEmpty ? "<empty>" : oldFragment

        return (
            system: """
            You decide whether user-corrected terms should be added to a speech transcription vocabulary.
            Only keep terms that are likely proper nouns, domain terms, product names, code identifiers, uncommon transliterations, or deliberate spellings that speech recognition should preserve.
            Exclude common everyday words, generic rewrites, punctuation-only changes, and phrases that do not look like vocabulary terms.
            Return strict JSON only in the form {"terms":["term1","term2"]}.
            Never wrap the JSON in Markdown code fences.
            Never include commentary, explanation, or any keys other than "terms".
            """,
            user: """
            Original dictated text:
            \(transcript)

            Previous edited fragment:
            \(oldSummary)

            Current edited fragment:
            \(newFragment)

            Candidate terms:
            \(candidateTerms.joined(separator: ", "))

            Existing vocabulary:
            \(existingSummary)

            Keep only the candidates that should be added to the vocabulary.
            Return strict JSON only.
            """
        )
    }

    static func askSelectionDecisionPrompts(
        selectedText: String,
        spokenInstruction: String,
        personaPrompt: String?
    ) -> (system: String, user: String) {
        let selectedTextSection = xmlSection(tag: "selected_text", content: selectedText)
        let spokenInstructionSection = xmlSection(tag: "spoken_instruction", content: spokenInstruction)
        let personaPrompt = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let personaSection = personaPrompt.isEmpty ? "" : """

        \(xmlSection(tag: "persona_definition", content: personaPrompt))
        """

        return (
            system: """
            You route "Ask Anything" requests about selected text.

            You must choose exactly one action:
            - "answer": The user is asking a question, requesting explanation, analysis, clarification, extraction of information, or any other read-only help. When you choose "answer", provide the final answer in the "response" field.
            - "edit": The user explicitly wants the selected text itself to be transformed and written back, such as rewriting, translating, shortening, expanding, fixing, reformatting, or changing tone. When you choose "edit", set "response" to an empty string.

            Stability rules:
            - Default to "answer" whenever the intent is ambiguous.
            - Never choose "edit" unless the user clearly wants to replace the selected text.
            - Persona instructions are secondary style guidance only. They must not force an "edit" decision.
            - Return strict JSON only.
            """,
            user: """
            \(selectedTextSection)

            \(spokenInstructionSection)\(personaSection)

            Decision guidance:
            - Questions like "what does this mean", "explain this", "is this correct", "what's wrong here", or "summarize what this says" are usually "answer".
            - Commands like "rewrite this", "translate this", "make this shorter", "fix the grammar", "turn this into bullet points", or "change the tone" are usually "edit".

            If you choose "answer", provide the final answer in "response".
            If you choose "edit", leave "response" as an empty string.
            """
        )
    }
}
