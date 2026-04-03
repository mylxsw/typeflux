import Foundation

extension DIContainer {
    var llmMultiTurnService: LLMMultiTurnService {
        OpenAICompatibleAgentService(settingsStore: settingsStore)
    }

    var mcpRegistry: MCPRegistry {
        MCPRegistry(settingsStore: MCPSettingsStore())
    }

    func makeAgentLoop(tools: [any AgentTool], config: AgentConfig = .default) async -> AgentLoop {
        let registry = AgentToolRegistry()
        await registry.registerAll(tools)
        return AgentLoop(llmService: llmMultiTurnService, toolRegistry: registry, config: config)
    }
}
