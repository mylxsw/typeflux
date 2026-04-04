import Foundation

/// Agent 执行结果（供 WorkflowController 使用）
enum AskAgentResult: Sendable {
    case answer(String)
    case edit(String)
}

extension WorkflowController {
    /// 使用 Agent 框架处理「随便问」请求
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        mcpTools: [any AgentTool] = [],
        skillTools: [any AgentTool] = [],
        skillPromptSupplements: [String] = []
    ) async throws -> AskAgentResult {
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        await registry.register(EditTextTool())
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        for tool in mcpTools {
            await registry.register(tool)
        }
        for tool in skillTools {
            await registry.register(tool)
        }

        let llmService = OpenAICompatibleAgentService(settingsStore: settingsStore)
        let loop = AgentLoop(
            llmService: llmService,
            toolRegistry: registry,
            config: .default
        )

        if settingsStore.agentStepLoggingEnabled {
            await loop.setStepMonitor(AgentStepLogger())
        }

        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.askAgentSystemPrompt(
                personaPrompt: personaPrompt,
                skillSupplements: skillPromptSupplements
            ),
            appLanguage: settingsStore.appLanguage
        )
        let userPrompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction
        )

        let result = try await loop.run(messages: [
            .system(systemPrompt),
            .user(userPrompt),
        ])

        switch result.outcome {
        case .text(let text):
            return .answer(text)
        case .terminationTool(let name, let args) where name == BuiltinAgentToolName.answerText.rawValue:
            return .answer(parseStringField("answer", from: args) ?? "")
        case .terminationTool(let name, let args) where name == BuiltinAgentToolName.editText.rawValue:
            return .edit(parseStringField("replacement", from: args) ?? "")
        case .maxStepsReached:
            throw AgentError.maxStepsExceeded
        case .error(let error):
            throw error
        default:
            throw AgentError.invalidAgentState(reason: "Unexpected outcome: \(result.outcome)")
        }
    }

    private func parseStringField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict[field] as? String
    }
}
