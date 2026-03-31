import Foundation

enum PromptCatalog {
    /// Builds the system prompt for a multimodal LLM transcription call.
    /// When a persona is provided, the model transcribes AND rewrites in one shot.
    /// Otherwise, it acts as a high-quality transcription engine with vocabulary hints.
    static func multimodalTranscriptionSystemPrompt(personaPrompt: String?, vocabularyTerms: [String]) -> String {
        var parts: [String] = []

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !persona.isEmpty {
            parts.append("""
            You are a transcription and text-rewriting assistant.
            Transcribe the audio accurately, then immediately rewrite the result according to the persona requirements below.
            Return only the final rewritten text — no explanations, no quotation marks, no meta-commentary.

            Persona requirements:
            \(persona)
            """)
        } else {
            parts.append("""
            You are a precise transcription assistant.
            Transcribe the audio accurately. Preserve the speaker's intent and natural phrasing.
            Return only the transcribed text — no explanations, no meta-commentary.
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
        let personaSection: String
        if let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !personaPrompt.isEmpty {
            personaSection = "\nPersona requirements:\n\(personaPrompt)"
        } else {
            personaSection = ""
        }

        switch request.mode {
        case .editSelection:
            let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outputRequirement: String
            if let personaPrompt = request.personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !personaPrompt.isEmpty {
                outputRequirement = """

                Output requirements:
                - Treat the spoken instruction as the highest-priority requirement.
                - Apply the persona requirement below only when it does not conflict with the edit intent.
                - Persona requirement: \(personaPrompt)
                """
            } else {
                outputRequirement = """

                Output requirements:
                - Treat the spoken instruction as the highest-priority requirement.
                """
            }

            return (
                system: "You are a text editing assistant. When editing existing text, preserve the user's editing intent first and use any persona requirement only as a secondary output-style constraint. Return only the final rewritten text without explanations or quotation marks.",
                user: """
                Selected text:
                \(request.sourceText)

                Spoken instruction:
                \(spokenInstruction)\(outputRequirement)

                Return only the final rewritten text.
                """
            )

        case .rewriteTranscript:
            return (
                system: "You rewrite dictated text into polished final copy. Follow the persona requirements exactly when provided. Return only the final text without explanations or quotation marks.",
                user: """
                Raw transcript:
                \(request.sourceText)\(personaSection)

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
