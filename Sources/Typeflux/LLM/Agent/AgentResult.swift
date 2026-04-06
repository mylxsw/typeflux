import Foundation

/// Agent execution result.
struct AgentResult {
    let outcome: AgentOutcome
    let steps: [AgentStep]
    let totalDurationMs: Int64
    let totalTokenUsage: LLMTokenUsage?

    init(
        outcome: AgentOutcome,
        steps: [AgentStep],
        totalDurationMs: Int64,
        totalTokenUsage: LLMTokenUsage? = nil,
    ) {
        self.outcome = outcome
        self.steps = steps
        self.totalDurationMs = totalDurationMs
        self.totalTokenUsage = totalTokenUsage
    }

    /// Extracts the final answer text (used by the answer_text tool).
    var answerText: String? {
        switch outcome {
        case let .text(text):
            text.isEmpty ? nil : text
        case let .terminationTool(name, args) where name == BuiltinAgentToolName.answerText.rawValue:
            extractStringField("answer", from: args)
        default:
            nil
        }
    }

    /// Extracts replacement text (used by the edit_text tool).
    var editedText: String? {
        guard case let .terminationTool(name, args) = outcome,
              name == BuiltinAgentToolName.editText.rawValue
        else {
            return nil
        }
        return extractStringField("replacement", from: args)
    }

    private func extractStringField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[field] as? String
        else {
            return nil
        }
        return value
    }
}
