import Foundation

struct AgentWorkflowRunner {
    private let settingsStore: SettingsStore
    private let clipboardService: ClipboardService

    init(settingsStore: SettingsStore, clipboardService: ClipboardService) {
        self.settingsStore = settingsStore
        self.clipboardService = clipboardService
    }

    func runAskAgent(
        systemPrompt: String,
        userMessage: String,
        extraTools: [any AgentTool] = [],
        config: AgentConfig = .default
    ) async throws -> AgentResult {
        let llmMultiTurnService = OpenAICompatibleAgentService(settingsStore: settingsStore)
        let registry = AgentToolRegistry()
        let builtinTools: [any AgentTool] = [
            AnswerTextTool(),
            EditTextTool(),
            GetClipboardTool(clipboardService: clipboardService),
        ]
        await registry.registerAll(builtinTools + extraTools)
        let loop = AgentLoop(llmService: llmMultiTurnService, toolRegistry: registry, config: config)
        return try await loop.run(messages: [
            .system(systemPrompt),
            .user(userMessage)
        ])
    }
}
