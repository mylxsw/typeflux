import Foundation

/// Generates a concise summary title for an agent job using an LLM.
enum AgentJobTitleGenerator {
    /// Generate a short title summarizing what the job did.
    /// Returns nil if generation fails (the job will keep its prompt-based title).
    static func generateTitle(
        for job: AgentJob,
        using llmService: LLMService,
        appLanguage: AppLanguage = .english
    ) async -> String? {
        let systemPrompt = """
            You generate short, descriptive titles for completed AI assistant tasks.
            Rules:
            - Return ONLY the title text, nothing else.
            - Keep it under 50 characters.
            - Use the same language as the user's request.
            - Be specific about what was done (e.g., "Translated email to Japanese" not "Processed text").
            - Do not use quotes, periods, or other punctuation at the end.
            """

        var userParts: [String] = []
        userParts.append("User request: \(job.userPrompt)")

        if let selected = job.selectedText, !selected.isEmpty {
            let truncated = String(selected.prefix(200))
            userParts.append("Context text: \(truncated)")
        }

        if let result = job.resultText, !result.isEmpty {
            let truncated = String(result.prefix(200))
            userParts.append("Result: \(truncated)")
        }

        if !job.steps.isEmpty {
            let toolNames = job.steps.flatMap { $0.toolCalls.map(\.name) }
            let uniqueTools = Array(Set(toolNames))
            if !uniqueTools.isEmpty {
                userParts.append("Tools used: \(uniqueTools.joined(separator: ", "))")
            }
        }

        userParts.append("Generate a short title for this task.")

        let userPrompt = userParts.joined(separator: "\n\n")

        do {
            let title = try await llmService.complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))

            guard !cleaned.isEmpty, cleaned.count <= 100 else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }
}
