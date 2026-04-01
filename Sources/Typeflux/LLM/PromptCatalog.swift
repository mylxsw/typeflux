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
}
