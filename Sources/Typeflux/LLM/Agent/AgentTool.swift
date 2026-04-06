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

/// Marker protocol for termination tools.
protocol TerminationTool: AgentTool {}

/// Built-in tool identifiers.
enum BuiltinAgentToolName: String, CaseIterable {
    case answerText = "answer_text"
    case editText = "edit_text"
    case getClipboard = "get_clipboard"
}
