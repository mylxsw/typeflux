import Foundation

/// Prompt catalog dedicated to the agent.
enum AgentPromptCatalog {
    // MARK: - Phase 1: Router prompts

    /// System prompt for the Phase 1 router — a single LLM call that decides how to handle the request.
    static func routerSystemPrompt(personaPrompt: String?) -> String {
        var parts: [String] = [
            """
            You are a request router for the Typeflux voice input assistant.

            Analyze the user's spoken request and select exactly one action by calling the corresponding tool:

            - answer_text: The request can be fully resolved in a single response — questions, explanations, analysis, summaries, or text transformations that require no external tools.
            - edit_text: The user wants their selected text replaced — rewrites, translations, reformatting, grammar fixes, or any direct text modification.
            - run_agent: The task genuinely requires multiple steps, external tool access (files, clipboard, web search), or complex reasoning that cannot be completed in one shot. When choosing this, rewrite the user's intent into a precise, unambiguous, and actionable instruction for the agent.

            Decision rules:
            - Default to answer_text for questions and explanations.
            - Use edit_text only when the user wants the selected text replaced.
            - Use run_agent only when the task truly cannot be done in a single response. Do not delegate simple tasks.
            - When you choose run_agent, write a detailed_instruction that: restates the goal precisely, resolves any implicit assumptions, and specifies the expected output format if relevant.
            """,
            PromptCatalog.languageConsistencyRule(for: "user's request"),
        ]

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty
        {
            parts.append(
                PromptCatalog.xmlSection(tag: "persona_definition", content: persona),
            )
        }

        return parts.joined(separator: "\n\n")
    }

    /// User prompt for the Phase 1 router.
    static func routerUserPrompt(selectedText: String?, instruction: String) -> String {
        var parts: [String] = []

        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty
        {
            parts.append(PromptCatalog.xmlSection(tag: "selected_text", content: selected))
        }

        parts.append(PromptCatalog.xmlSection(
            tag: "spoken_request",
            content: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
        ))

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Phase 2: Full agent loop prompts

    /// System prompt for the Phase 2 full agent loop.
    static func agentSystemPrompt(personaPrompt: String?) -> String {
        var parts: [String] = [
            """
            You are a capable AI agent for the Typeflux voice input assistant. You have access to tools and can execute multi-step tasks.

            Your inputs are organized using XML tags:
            - <task_instruction>: The primary instruction to execute. This is a clarified and precise version of the user's intent — treat it as the authoritative task definition.
            - <original_request>: The user's original spoken request, provided for reference and context only.
            - <selected_text>: Text the user had selected when making the request (if any).

            When you use tools, structure intermediate reasoning clearly. Call answer_text to present a final answer to the user, or edit_text to replace their selected text.

            Additional tools from connected MCP servers may also be available — use them when appropriate to fulfil the task.

            Decision rules:
            - Default to answer_text for questions, explanations, and read-only results.
            - Use edit_text only when the task explicitly requires replacing the selected text.
            - If unsure, prefer answer_text over edit_text.
            """,
            PromptCatalog.languageConsistencyRule(for: "task_instruction and original_request"),
        ]

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty
        {
            parts.append(
                PromptCatalog.xmlSection(tag: "persona_definition", content: persona),
            )
        }

        return parts.joined(separator: "\n\n")
    }

    /// User prompt for the Phase 2 full agent loop.
    /// - Parameters:
    ///   - selectedText: The text the user had selected (if any).
    ///   - spokenInstruction: The user's original spoken request (for reference).
    ///   - detailedInstruction: The clarified instruction produced by the Phase 1 router.
    static func agentUserPrompt(
        selectedText: String?,
        spokenInstruction: String,
        detailedInstruction: String,
    ) -> String {
        var parts: [String] = []

        parts.append(PromptCatalog.xmlSection(
            tag: "task_instruction",
            content: detailedInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
        ))

        parts.append(PromptCatalog.xmlSection(
            tag: "original_request",
            content: spokenInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
        ))

        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty
        {
            parts.append(PromptCatalog.xmlSection(tag: "selected_text", content: selected))
        }

        return parts.joined(separator: "\n\n")
    }
}
