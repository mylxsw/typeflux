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

/// Captures Phase 1 execution metadata for inclusion in the Phase 2 job record.
private struct Phase1RouterResult {
    let decision: Phase1Decision
    let toolCallName: String
    let toolCallArgumentsJSON: String
    let durationMs: Int64
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

        // Create the job recorder upfront so every invocation—regardless of routing
        // decision—produces a history record.
        let jobRecorder = AgentJobRecorder(store: agentJobStore, jobID: UUID())
        await jobRecorder.beginJob(userPrompt: spokenInstruction, selectedText: selectedText)

        // Phase 1: single LLM tool call that routes to answer_text, edit_text, or run_agent.
        let phase1Result: Phase1RouterResult
        do {
            phase1Result = try await runPhase1Router(
                selectedText: selectedText,
                spokenInstruction: spokenInstruction,
                personaPrompt: personaPrompt,
                llmService: llmService,
            )
        } catch {
            await jobRecorder.markFailed(error: error)
            throw error
        }

        // Record Phase 1 as step 0 in all cases.
        let phase1ResultContent: String = switch phase1Result.decision {
        case let .answer(text): text
        case let .edit(text): text
        case .runAgent: ""
        }
        await jobRecorder.addPhase1Step(
            toolCallName: phase1Result.toolCallName,
            toolCallArgumentsJSON: phase1Result.toolCallArgumentsJSON,
            resultContent: phase1ResultContent,
            durationMs: phase1Result.durationMs,
        )

        switch phase1Result.decision {
        case let .answer(text):
            await jobRecorder.completeWithPhase1Result(resultText: text, outcomeType: "answer_text")
            scheduleJobTitle(for: jobRecorder.recordedJobID)
            return .answer(text)
        case let .edit(text):
            await jobRecorder.completeWithPhase1Result(resultText: text, outcomeType: "edit_text")
            scheduleJobTitle(for: jobRecorder.recordedJobID)
            return .edit(text)
        case let .runAgent(detailedInstruction):
            // Phase 2: full agent loop continues in the same job; steps start at index 1.
            return try await runPhase2AgentLoop(
                selectedText: selectedText,
                spokenInstruction: spokenInstruction,
                detailedInstruction: detailedInstruction,
                personaPrompt: personaPrompt,
                llmService: llmService,
                jobRecorder: jobRecorder,
            )
        }
    }

    // MARK: - Phase 1

    private func runPhase1Router(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        llmService: OpenAICompatibleAgentService,
    ) async throws -> Phase1RouterResult {
        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.routerSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )
        let userPrompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction,
        )
        let tools = [AnswerTextTool().definition, EditTextTool().definition, RunAgentTool().definition]

        let start = DispatchTime.now()
        let toolCall = try await llmService.runAnyTool(
            request: LLMAgentRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                tools: tools,
            ),
        )
        let end = DispatchTime.now()
        let durationMs = Int64((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        let decision: Phase1Decision
        switch toolCall.name {
        case BuiltinAgentToolName.answerText.rawValue:
            let text = parseStringField("answer", from: toolCall.argumentsJSON) ?? ""
            decision = .answer(text)
        case BuiltinAgentToolName.editText.rawValue:
            let text = parseStringField("replacement", from: toolCall.argumentsJSON) ?? ""
            decision = .edit(text)
        case BuiltinAgentToolName.runAgent.rawValue:
            let instruction = parseStringField("detailed_instruction", from: toolCall.argumentsJSON)
                ?? spokenInstruction
            decision = .runAgent(detailedInstruction: instruction)
        default:
            throw AgentError.invalidAgentState(reason: "Unexpected Phase 1 tool: \(toolCall.name)")
        }

        return Phase1RouterResult(
            decision: decision,
            toolCallName: toolCall.name,
            toolCallArgumentsJSON: toolCall.argumentsJSON,
            durationMs: durationMs,
        )
    }

    // MARK: - Phase 2

    // swiftlint:disable:next function_body_length function_parameter_count
    private func runPhase2AgentLoop(
        selectedText: String?,
        spokenInstruction: String,
        detailedInstruction: String,
        personaPrompt: String?,
        llmService: OpenAICompatibleAgentService,
        jobRecorder: AgentJobRecorder,
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

        // Phase 2 steps start at index 1; index 0 is the Phase 1 routing step.
        let phase2Config = AgentConfig(
            maxSteps: AgentConfig.default.maxSteps,
            allowParallelToolCalls: AgentConfig.default.allowParallelToolCalls,
            temperature: AgentConfig.default.temperature,
            enableStreaming: AgentConfig.default.enableStreaming,
            initialStepIndex: 1,
        )

        let loop = AgentLoop(
            llmService: llmService,
            toolRegistry: registry,
            config: phase2Config,
        )
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

        scheduleJobTitle(for: jobRecorder.recordedJobID)

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

    /// Asynchronously generates and saves a summary title for the given job.
    private func scheduleJobTitle(for jobID: UUID) {
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
