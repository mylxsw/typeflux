import Foundation

/// Agent execution result for the WorkflowController.
enum AskAgentResult {
    case answer(String)
    case edit(String)
}

struct AskAgentExecutionResult {
    let jobID: UUID
    let result: AskAgentResult
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
    ///   If the model returns plain text (clarification question) instead of a tool call,
    ///   a clarification dialog is shown and the user can reply via voice to continue.
    ///
    /// - Phase 2 (conditional): Triggered only when Phase 1 returns `run_agent`. Runs the full
    ///   `AgentLoop` with MCP tools and job recording, using the clarified instruction from Phase 1.
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        jobID: UUID = UUID(),
        appSystemContext: AppSystemContext? = nil,
    ) async throws -> AskAgentExecutionResult {
        let configStatus = await validateLLMConfiguration()
        guard case .ready = configStatus else {
            await presentLLMNotConfigured(configStatus)
            if case .notConfigured(let reason) = configStatus {
                throw LLMConfigurationError.notConfigured(reason: reason)
            }
            throw CancellationError()
        }

        let llmService = OpenAICompatibleAgentService(settingsStore: settingsStore)

        // Create the job recorder upfront so every invocation—regardless of routing
        // decision—produces a history record.
        let jobRecorder = AgentJobRecorder(store: agentJobStore, jobID: jobID)
        await jobRecorder.beginJob(userPrompt: spokenInstruction, selectedText: selectedText)

        // Phase 1 retry loop: if the model asks for clarification, show the dialog and retry.
        var clarificationTurns: [(modelText: String, userReply: String)] = []
        while true {
            let phase1Result: Phase1RouterResult
            do {
                phase1Result = try await runPhase1Router(
                    selectedText: selectedText,
                    spokenInstruction: spokenInstruction,
                    personaPrompt: personaPrompt,
                    appSystemContext: appSystemContext,
                    llmService: llmService,
                    clarificationTurns: clarificationTurns,
                )
            } catch is CancellationError {
                await jobRecorder.markCancelled(message: L("workflow.cancel.userCancelled"))
                throw CancellationError()
            } catch LLMAgentError.textResponse(let modelText) {
                // The model returned a clarification question instead of a tool call.
                // Show the clarification dialog and wait for the user's voice reply.
                let userReply: String
                do {
                    userReply = try await showClarificationAndWaitForReply(
                        modelResponse: modelText,
                        question: spokenInstruction,
                        selectedText: selectedText,
                    )
                } catch {
                    await jobRecorder.markCancelled(message: L("workflow.cancel.userCancelled"))
                    throw CancellationError()
                }
                clarificationTurns.append((modelText: modelText, userReply: userReply))
                continue
            } catch {
                await jobRecorder.markFailed(error: error)
                throw error
            }

            // Phase 1 succeeded — record step 0 and dispatch.
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
                return AskAgentExecutionResult(jobID: jobRecorder.recordedJobID, result: .answer(text))
            case let .edit(text):
                await jobRecorder.completeWithPhase1Result(resultText: text, outcomeType: "edit_text")
                scheduleJobTitle(for: jobRecorder.recordedJobID)
                return AskAgentExecutionResult(jobID: jobRecorder.recordedJobID, result: .edit(text))
            case let .runAgent(detailedInstruction):
                // Phase 2: full agent loop continues in the same job; steps start at index 1.
                let result = try await runPhase2AgentLoop(
                    selectedText: selectedText,
                    spokenInstruction: spokenInstruction,
                    detailedInstruction: detailedInstruction,
                    personaPrompt: personaPrompt,
                    appSystemContext: appSystemContext,
                    llmService: llmService,
                    jobRecorder: jobRecorder,
                )
                return AskAgentExecutionResult(jobID: jobRecorder.recordedJobID, result: result)
            }
        }
    }

    // MARK: - Clarification dialog

    /// Shows the clarification dialog and suspends until the user records a voice reply or dismisses.
    /// Throws `CancellationError` if the user closes the dialog without replying.
    private func showClarificationAndWaitForReply(
        modelResponse: String,
        question: String,
        selectedText: String?,
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            pendingClarificationContinuation = continuation
            agentClarificationWindowController.show(
                question: question,
                selectedText: selectedText,
                modelResponse: modelResponse,
            )
        }
    }

    // MARK: - Phase 1

    private func runPhase1Router(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        appSystemContext: AppSystemContext?,
        llmService: OpenAICompatibleAgentService,
        clarificationTurns: [(modelText: String, userReply: String)] = [],
    ) async throws -> Phase1RouterResult {
        let systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.routerSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )

        // Append clarification history to the instruction so the model has full context.
        var instruction = spokenInstruction
        if !clarificationTurns.isEmpty {
            instruction += clarificationTurns.map { turn in
                "\n\n[Assistant asked for clarification]: \(turn.modelText)\n[User replied]: \(turn.userReply)"
            }.joined()
        }

        let userPrompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: selectedText,
            instruction: instruction,
        )
        let tools = [AnswerTextTool().definition, EditTextTool().definition, RunAgentTool().definition]

        let start = DispatchTime.now()
        let toolCall = try await llmService.runAnyTool(
            request: LLMAgentRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                tools: tools,
                appSystemContext: appSystemContext,
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
            let resolvedInstruction = parseStringField("detailed_instruction", from: toolCall.argumentsJSON)
                ?? spokenInstruction
            decision = .runAgent(detailedInstruction: resolvedInstruction)
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
        appSystemContext: AppSystemContext?,
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

        var systemPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: AgentPromptCatalog.agentSystemPrompt(personaPrompt: personaPrompt),
            appLanguage: settingsStore.appLanguage,
        )
        if let appContext = appSystemContext {
            let extra = PromptCatalog.appSpecificSystemContext(appContext)
            if !extra.isEmpty {
                systemPrompt = PromptCatalog.appendAdditionalSystemContext(
                    extra,
                    to: systemPrompt,
                )
            }
        }
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
        } catch is CancellationError {
            await jobRecorder.markCancelled(message: L("workflow.cancel.userCancelled"))
            throw CancellationError()
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
