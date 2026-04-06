import Foundation

/// Agent execution result for the WorkflowController.
enum AskAgentResult {
    case answer(String)
    case edit(String)
}

extension WorkflowController {
    /// Run an agent-powered "Ask Anything" request with job recording.
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
    ) async throws -> AskAgentResult {
        // Connect all enabled MCP servers (already-connected servers are skipped)
        await mcpRegistry.connectEnabledServers(settingsStore.mcpServers)
        let mcpTools = await mcpRegistry.allMCPTools()

        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        await registry.register(EditTextTool())
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        for tool in mcpTools {
            await registry.register(tool)
        }

        let llmService = OpenAICompatibleAgentService(settingsStore: settingsStore)
        let loop = AgentLoop(
            llmService: llmService,
            toolRegistry: registry,
            config: .default,
        )

        // Set up job recorder as the step monitor
        let jobRecorder = AgentJobRecorder(store: agentJobStore, jobID: UUID())
        await jobRecorder.beginJob(userPrompt: spokenInstruction, selectedText: selectedText)
        await loop.setStepMonitor(jobRecorder)

        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )
        let userPrompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction,
        )

        let result: AgentResult
        do {
            result = try await loop.run(messages: [
                .system(systemPrompt),
                .user(userPrompt),
            ])
        } catch {
            await jobRecorder.markFailed(error: error)
            throw error
        }

        // Generate a summary title asynchronously (fire-and-forget)
        let jobID = jobRecorder.recordedJobID
        let jobStore = agentJobStore
        let titleLLMService = LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: OllamaLocalModelManager()),
        )
        Task.detached {
            if var job = try? await jobStore.job(id: jobID) {
                let title = await AgentJobTitleGenerator.generateTitle(
                    for: job,
                    using: titleLLMService,
                    appLanguage: self.settingsStore.appLanguage,
                )
                if let title {
                    job.title = title
                    try? await jobStore.save(job)
                }
            }
        }

        switch result.outcome {
        case let .text(text):
            return .answer(text)
        case let .terminationTool(name, args) where name == BuiltinAgentToolName.answerText.rawValue:
            return .answer(parseStringField("answer", from: args) ?? "")
        case let .terminationTool(name, args) where name == BuiltinAgentToolName.editText.rawValue:
            return .edit(parseStringField("replacement", from: args) ?? "")
        case .maxStepsReached:
            throw AgentError.maxStepsExceeded
        case let .error(error):
            throw error
        default:
            throw AgentError.invalidAgentState(reason: "Unexpected outcome: \(result.outcome)")
        }
    }

    private func parseStringField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict[field] as? String
    }
}
