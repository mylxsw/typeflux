import Foundation

/// Agent 执行结果
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

    /// 提取最终答案文本（用于 answer_text 工具）
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

    /// 提取要替换的文本（用于 edit_text 工具）
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
