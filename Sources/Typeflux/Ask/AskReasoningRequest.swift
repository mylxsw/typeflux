import Foundation

/// Translates Ask's provider-neutral `reasoning_effort` into each provider's own
/// thinking parameters, so the user's choice also applies to their own models.
/// Ask never turns thinking off: without a choice the provider default is used.
enum AskReasoningRequest {
    /// Extended-thinking budgets for the Anthropic Messages API.
    static let anthropicBudgets = ["low": 2048, "medium": 8192, "high": 16384]
    /// Thinking budgets for the Gemini API.
    static let geminiBudgets = ["low": 1024, "medium": 8192, "high": 24576]

    static func effort(in body: [String: Any]) -> String? {
        guard let effort = body["reasoning_effort"] as? String, anthropicBudgets[effort] != nil else { return nil }
        return effort
    }

    /// Enables Anthropic extended thinking. A turn that answers tool results is left alone:
    /// Anthropic requires the thinking block of that tool call to be sent back, and the
    /// bridge does not keep it.
    static func applyAnthropic(effort: String?, to native: inout [String: Any]) {
        guard let effort, let budget = anthropicBudgets[effort] else { return }
        let last = (native["messages"] as? [[String: Any]])?.last
        let parts = last?["content"] as? [[String: Any]] ?? []
        guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return }
        native["thinking"] = ["type": "enabled", "budget_tokens": budget]
        // max_tokens must exceed the thinking budget and still leave room for the answer.
        let answer = native["max_tokens"] as? Int ?? AskLocalPrompt.maxAnswerTokens
        native["max_tokens"] = budget + answer
    }

    /// Sets Gemini's thinking budget and asks for thought summaries to show in the transcript.
    static func applyGemini(effort: String?, to native: inout [String: Any]) {
        guard let effort, let budget = geminiBudgets[effort] else { return }
        var config = native["generationConfig"] as? [String: Any] ?? [:]
        config["thinkingConfig"] = ["thinkingBudget": budget, "includeThoughts": true]
        native["generationConfig"] = config
    }

    /// Removes every reasoning parameter; returns whether anything was removed.
    @discardableResult
    static func strip(_ body: inout [String: Any]) -> Bool {
        var removed = body.removeValue(forKey: "reasoning_effort") != nil
        removed = body.removeValue(forKey: "thinking") != nil || removed
        if var config = body["generationConfig"] as? [String: Any], config.removeValue(forKey: "thinkingConfig") != nil {
            body["generationConfig"] = config.isEmpty ? nil : config
            removed = true
        }
        return removed
    }

    /// Providers answer an unknown or unsupported parameter with 400 or 422.
    static func isRejection(status: Int) -> Bool {
        status == 400 || status == 422
    }

    /// Sends `body`; when the provider rejects it and it carried reasoning parameters,
    /// retries once without them so an unsupported effort never breaks the answer.
    static func send<T>(_ body: [String: Any], _ attempt: ([String: Any]) async throws -> T) async throws -> T {
        do {
            return try await attempt(body)
        } catch AskStreamError.rejected {
            var fallback = body
            guard strip(&fallback) else { throw AskLocalError.message(L("ask.models.requestError")) }
            do {
                return try await attempt(fallback)
            } catch AskStreamError.rejected {
                throw AskLocalError.message(L("ask.models.requestError"))
            }
        }
    }
}
