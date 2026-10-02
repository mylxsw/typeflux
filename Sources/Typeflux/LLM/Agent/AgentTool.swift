import Foundation

/// Agent tool protocol.
protocol AgentTool: Sendable {
    /// Tool definition (name, description, input schema).
    var definition: LLMAgentTool { get }
    /// Executes the tool.
    /// - Parameter arguments: JSON string arguments.
    /// - Returns: Execution result (text or JSON string).
    func execute(arguments: String) async throws -> String
}

