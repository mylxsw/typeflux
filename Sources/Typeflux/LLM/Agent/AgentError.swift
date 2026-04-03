import Foundation

enum AgentError: LocalizedError, Equatable, Sendable {
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
            return "Agent reached maximum execution steps without terminating."
        case .toolNotFound(let name):
            return "Tool '\(name)' not found in registry."
        case .toolExecutionFailed(let name, let reason):
            return "Tool '\(name)' execution failed: \(reason)"
        case .mcpConnectionFailed(let serverName, let reason):
            return "MCP server '\(serverName)' connection failed: \(reason)"
        case .mcpServerNotFound(let id):
            return "MCP server with ID \(id) not found."
        case .invalidAgentState(let reason):
            return "Invalid agent state: \(reason)"
        case .llmConnectionFailed(let reason):
            return "LLM connection failed: \(reason)"
        }
    }
}
