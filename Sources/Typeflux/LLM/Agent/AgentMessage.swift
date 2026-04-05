import Foundation

/// 消息角色
enum AgentMessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// 单个工具调用
struct AgentToolCall: Equatable, Codable {
    let id: String
    let name: String
    let argumentsJSON: String
}

/// 工具执行结果
struct AgentToolResult: Equatable, Codable {
    let toolCallId: String
    let content: String
    let isError: Bool
}

/// 助手消息（文本 + 工具调用）
struct AgentAssistantMessage: Equatable, Codable {
    let text: String?
    let toolCalls: [AgentToolCall]
}

/// 单条消息联合类型
enum AgentMessage: Equatable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantMessage)
    case toolResult(AgentToolResult)
}
