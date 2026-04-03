import Foundation

/// 工具注册表 actor
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

    /// 执行工具
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

    /// 获取所有工具定义（用于 LLM 调用）
    var definitions: [LLMAgentTool] {
        tools.values.map(\.definition)
    }

    /// 检查是否为终止工具
    func isTerminationTool(name: String) -> Bool {
        terminationToolNames.contains(name)
    }

    /// 检查工具是否存在
    func hasTool(name: String) -> Bool {
        tools[name] != nil
    }
}
