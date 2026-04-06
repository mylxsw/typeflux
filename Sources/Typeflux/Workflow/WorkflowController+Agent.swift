import Foundation

/// Agent execution result for the WorkflowController.
enum AskAgentResult {
    case answer(String)
    case edit(String)
}

/// Internal Phase 1 routing decision.
private enum Phase1Decision {
    case answer(String)
    case edit(String)
    case runAgent(detailedInstruction: String)
}

extension WorkflowController {
    /// Run an agent-powered "Ask Anything" request using a two-phase approach:
    ///
    /// - Phase 1: A single LLM tool call that routes the request to `answer_text`, `edit_text`,
    ///   or `run_agent`. Simple requests are resolved immediately with no job recording overhead.
    ///
    /// - Phase 2 (conditional): Triggered only when Phase 1 returns `run_agent`. Runs the full
    ///   `AgentLoop` with MCP tools and job recording, using the clarified instruction from Phase 1.
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
    ) async throws -> AskAgentResult {
        let llmService = OpenAICompatibleAgentService(settingsStore: settingsStore)

        // Phase 1: single tool call, no MCP, no job recording
        let phase1 = try await runPhase1Router(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            personaPrompt: personaPrompt,
            llmService: llmService,
        )

        switch phase1 {
        case let .answer(text):
            return .answer(text)
        case let .edit(text):
            return .edit(text)
        case let .runAgent(detailedInstruction):
            // Phase 2: full agent loop with MCP and job recording
            return try await runPhase2AgentLoop(
                selectedText: selectedText,
                spokenInstruction: spokenInstruction,
                detailedInstruction: detailedInstruction,
                personaPrompt: personaPrompt,
                llmService: llmService,
            )
        }
    }

    // MARK: - Phase 1

    private func runPhase1Router(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        llmService: OpenAICompatibleAgentService,
    ) async throws -> Phase1Decision {
        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.routerSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )
        let userPrompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction,
        )
        let tools = [AnswerTextTool().definition, EditTextTool().definition, RunAgentTool().definition]

        let toolCall = try await llmService.runAnyTool(
            request: LLMAgentRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                tools: tools,
            ),
        )

        switch toolCall.name {
        case BuiltinAgentToolName.answerText.rawValue:
            let text = parseStringField("answer", from: toolCall.argumentsJSON) ?? ""
            return .answer(text)
        case BuiltinAgentToolName.editText.rawValue:
            let text = parseStringField("replacement", from: toolCall.argumentsJSON) ?? ""
            return .edit(text)
        case BuiltinAgentToolName.runAgent.rawValue:
            let instruction = parseStringField("detailed_instruction", from: toolCall.argumentsJSON)
                ?? spokenInstruction
            return .runAgent(detailedInstruction: instruction)
        default:
            throw AgentError.invalidAgentState(reason: "Unexpected Phase 1 tool: \(toolCall.name)")
        }
    }

    // MARK: - Phase 2

    private func runPhase2AgentLoop(
        selectedText: String?,
        spokenInstruction: String,
        detailedInstruction: String,
        personaPrompt: String?,
        llmService: OpenAICompatibleAgentService,
    ) async throws -> AskAgentResult {
        // Connect MCP servers (only in Phase 2)
        await mcpRegistry.connectEnabledServers(settingsStore.mcpServers)
        let mcpTools = await mcpRegistry.allMCPTools()

        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        await registry.register(EditTextTool())
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        for tool in mcpTools {
            await registry.register(tool)
        }

        let loop = AgentLoop(
            llmService: llmService,
            toolRegistry: registry,
            config: .default,
        )

        // Set up job recorder for Phase 2 only
        let jobRecorder = AgentJobRecorder(store: agentJobStore, jobID: UUID())
        await jobRecorder.beginJob(userPrompt: spokenInstruction, selectedText: selectedText)
        await loop.setStepMonitor(jobRecorder)

        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.agentSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )
        let userPrompt = AgentPromptCatalog.agentUserPrompt(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            detailedInstruction: detailedInstruction,
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

    // MARK: - Helpers

    private func parseStringField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict[field] as? String
    }
}
