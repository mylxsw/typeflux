import Foundation

/// 单轮 LLM 输出
enum AgentTurn: Sendable {
    /// 纯文本回复
    case text(String)
    /// 工具调用
    case toolCalls([AgentToolCall])
    /// 文本 + 工具调用
    case textWithToolCalls(text: String, toolCalls: [AgentToolCall])
}

/// 调用配置
struct LLMCallConfig: Sendable {
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
    /// - Returns: LLM 本轮输出
    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn
}
