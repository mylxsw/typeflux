import Foundation

enum AgentError: LocalizedError, Equatable {
    case maxStepsExceeded
    case toolNotFound(name: String)
    case toolExecutionFailed(name: String, reason: String)
    case mcpConnectionFailed(serverName: String, reason: String)
    case mcpServerNotFound(id: UUID)
    case invalidAgentState(reason: String)
    case llmConnectionFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .maxStepsExceeded:
            "Agent reached maximum execution steps without terminating."
        case let .toolNotFound(name):
            "Tool '\(name)' not found in registry."
        case let .toolExecutionFailed(name, reason):
            "Tool '\(name)' execution failed: \(reason)"
        case let .mcpConnectionFailed(serverName, reason):
            "MCP server '\(serverName)' connection failed: \(reason)"
        case let .mcpServerNotFound(id):
            "MCP server with ID \(id) not found."
        case let .invalidAgentState(reason):
            "Invalid agent state: \(reason)"
        case let .llmConnectionFailed(reason):
            "LLM connection failed: \(reason)"
        }
    }
}
