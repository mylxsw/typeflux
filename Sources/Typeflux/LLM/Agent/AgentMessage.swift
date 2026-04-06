import Foundation

/// Message role.
enum AgentMessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A single tool call.
struct AgentToolCall: Equatable, Codable {
    let id: String
    let name: String
    let argumentsJSON: String
}

/// Tool execution result.
struct AgentToolResult: Equatable, Codable {
    let toolCallId: String
    let content: String
    let isError: Bool
}

/// Assistant message (text + tool calls).
struct AgentAssistantMessage: Equatable, Codable {
    let text: String?
    let toolCalls: [AgentToolCall]
}

/// Union type for a single message.
enum AgentMessage: Equatable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantMessage)
    case toolResult(AgentToolResult)
}
