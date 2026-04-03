import Foundation

/// Agent 专用提示词目录
enum AgentPromptCatalog {
    /// Agent 系统提示词
    static func askAgentSystemPrompt(personaPrompt: String?) -> String {
        var parts: [String] = [
            """
            You are a helpful AI assistant for the Typeflux voice input app.

            You have access to various tools to help answer the user's questions or modify their selected text.

            Available tools:
            - answer_text: Present a final answer to the user in a popup window. Use when the user asks a question, wants explanation, analysis, or any read-only information.
            - edit_text: Replace the user's selected text with new content. Use when the user explicitly wants to rewrite, translate, shorten, expand, fix, or reformat their selected text.
            - get_clipboard: Read the current clipboard content. Use when the user references content from their clipboard.

            Decision rules:
            - Default to answer_text for questions, explanations, and analysis.
            - Use edit_text only when the user clearly wants to transform their selected text.
            - If unsure, prefer answer_text (read-only) over edit_text.

            If the user asks a follow-up question after seeing your answer, continue the conversation naturally.
            """,
            PromptCatalog.languageConsistencyRule(for: "user's request"),
        ]

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty {
            parts.append(
                """
                Persona/style guidance:
                \(persona)
                """)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Agent 用户提示词
    static func askAgentUserPrompt(selectedText: String?, instruction: String) -> String {
        var parts: [String] = []

        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            parts.append("Selected text:\n---\n\(selected)\n---")
        }

        parts.append("User request: \(instruction)")

        return parts.joined(separator: "\n\n")
    }
}
