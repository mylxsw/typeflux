import Foundation

/// Tool registry actor.
actor AgentToolRegistry {
    private var tools: [String: any AgentTool] = [:]
    private var terminationToolNames: Set<String> = []

    func register(_ tool: any AgentTool) {
        tools[tool.definition.name] = tool
        if tool is any TerminationTool {
            terminationToolNames.insert(tool.definition.name)
        }
    }

    func registerAll(_ tools: [any AgentTool]) {
        for tool in tools {
            register(tool)
        }
    }

    func unregister(name: String) {
        tools.removeValue(forKey: name)
        terminationToolNames.remove(name)
    }

    /// Executes a tool.
    func execute(name: String, arguments: String, toolCallId: String) async throws -> AgentToolResult {
        guard let tool = tools[name] else {
            throw AgentError.toolNotFound(name: name)
        }
        do {
            let content = try await tool.execute(arguments: arguments)
            return AgentToolResult(toolCallId: toolCallId, content: content, isError: false)
        } catch {
            return AgentToolResult(toolCallId: toolCallId, content: error.localizedDescription, isError: true)
        }
    }

    /// Returns all tool definitions (for LLM calls).
    var definitions: [LLMAgentTool] {
        tools.values.map(\.definition)
    }

    /// Checks whether a tool is a termination tool.
    func isTerminationTool(name: String) -> Bool {
        terminationToolNames.contains(name)
    }

    /// Checks whether a tool exists.
    func hasTool(name: String) -> Bool {
        tools[name] != nil
    }
}
