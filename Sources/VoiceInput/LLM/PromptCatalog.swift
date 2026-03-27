import Foundation

enum PromptCatalog {
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
}
