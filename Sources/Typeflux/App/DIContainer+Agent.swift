import Foundation

extension DIContainer {
    var llmMultiTurnService: LLMMultiTurnService {
        OpenAICompatibleAgentService(settingsStore: settingsStore)
    }

    func makeAgentLoop(tools: [any AgentTool], config: AgentConfig = .default) async -> AgentLoop {
        let registry = AgentToolRegistry()
        await registry.registerAll(tools)
        return AgentLoop(llmService: llmMultiTurnService, toolRegistry: registry, config: config)
    }
}
