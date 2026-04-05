import Foundation

/// 单轮 LLM 输出
enum AgentTurn {
    /// 纯文本回复
    case text(String)
    /// 工具调用
    case toolCalls([AgentToolCall])
    /// 文本 + 工具调用
    case textWithToolCalls(text: String, toolCalls: [AgentToolCall])
}

/// Token usage information from a single LLM API call.
struct LLMTokenUsage: Codable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    static func + (lhs: LLMTokenUsage, rhs: LLMTokenUsage) -> LLMTokenUsage {
        LLMTokenUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
        )
    }
}

/// Result of a single LLM turn, including optional token usage.
struct AgentTurnResult {
    let turn: AgentTurn
    let tokenUsage: LLMTokenUsage?
}

/// 调用配置
struct LLMCallConfig {
    /// 强制使用某个工具（nil 表示模型自由选择）
    let forcedToolName: String?
    /// 允许并行工具调用
    let parallelToolCalls: Bool
    /// 温度参数
    let temperature: Double?
}

/// 多轮 LLM 服务协议
protocol LLMMultiTurnService: Sendable {
    /// 执行多轮对话
    /// - Parameters:
    ///   - messages: 消息历史（包含 system、user、assistant、toolResult）
    ///   - tools: 可用工具定义列表
    ///   - config: 调用配置
    /// - Returns: LLM 本轮输出及 token 用量
    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig,
    ) async throws -> AgentTurnResult
}
