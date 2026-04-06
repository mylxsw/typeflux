import Foundation

/// AgentLoop - core execution engine.
actor AgentLoop {
    private let llmService: LLMMultiTurnService
    private let toolRegistry: AgentToolRegistry
    private let config: AgentConfig
    private var stepMonitor: (any AgentStepMonitor)?

    init(
        llmService: LLMMultiTurnService,
        toolRegistry: AgentToolRegistry,
        config: AgentConfig = .default,
    ) {
        self.llmService = llmService
        self.toolRegistry = toolRegistry
        self.config = config
    }

    /// Sets the step monitor.
    func setStepMonitor(_ monitor: (any AgentStepMonitor)?) {
        stepMonitor = monitor
    }

    /// Runs the agent.
    /// - Parameters:
    ///   - messages: Initial messages (usually system + user).
    ///   - streamHandler: Streaming text output callback (optional).
    /// - Returns: Agent execution result.
    func run(
        messages: [AgentMessage],
        streamHandler: ((String) -> Void)? = nil,
    ) async throws -> AgentResult {
        var accumulatedMessages = messages
        var accumulatedText = ""
        var steps: [AgentStep] = []
        let startTime = DispatchTime.now()
        var cumulativeTokenUsage: LLMTokenUsage? = nil

        for stepIndex in config.initialStepIndex ..< (config.initialStepIndex + config.maxSteps) {
            let stepStart = DispatchTime.now()

            let callConfig = LLMCallConfig(
                forcedToolName: nil,
                parallelToolCalls: config.allowParallelToolCalls,
                temperature: config.temperature,
            )

            let turnResult = try await llmService.complete(
                messages: accumulatedMessages,
                tools: toolRegistry.definitions,
                config: callConfig,
            )

            // Accumulate token usage across all LLM calls
            if let usage = turnResult.tokenUsage {
                cumulativeTokenUsage = cumulativeTokenUsage.map { $0 + usage } ?? usage
            }

            switch turnResult.turn {
            case let .text(text):
                if !text.isEmpty {
                    accumulatedText += text
                    streamHandler?(text)
                }
                let outcome = AgentOutcome.text(accumulatedText)
                await stepMonitor?.agentDidFinish(outcome: outcome, totalTokenUsage: cumulativeTokenUsage)
                return AgentResult(
                    outcome: outcome,
                    steps: steps,
                    totalDurationMs: elapsedMs(from: startTime),
                    totalTokenUsage: cumulativeTokenUsage,
                )

            case let .toolCalls(toolCalls):
                let (newSteps, terminationResult) = try await processToolCalls(
                    toolCalls: toolCalls,
                    assistantText: nil,
                    stepIndex: stepIndex,
                    stepStart: stepStart,
                    tokenUsage: turnResult.tokenUsage,
                    accumulatedMessages: &accumulatedMessages,
                    steps: steps,
                    totalStart: startTime,
                    cumulativeTokenUsage: cumulativeTokenUsage,
                )
                steps = newSteps
                if let result = terminationResult {
                    await stepMonitor?.agentDidFinish(outcome: result.outcome, totalTokenUsage: result.totalTokenUsage)
                    return result
                }

            case let .textWithToolCalls(text, toolCalls):
                if !text.isEmpty {
                    accumulatedText += text
                    streamHandler?(text)
                }
                let (newSteps, terminationResult) = try await processToolCalls(
                    toolCalls: toolCalls,
                    assistantText: text.isEmpty ? nil : text,
                    stepIndex: stepIndex,
                    stepStart: stepStart,
                    tokenUsage: turnResult.tokenUsage,
                    accumulatedMessages: &accumulatedMessages,
                    steps: steps,
                    totalStart: startTime,
                    cumulativeTokenUsage: cumulativeTokenUsage,
                )
                steps = newSteps
                if let result = terminationResult {
                    await stepMonitor?.agentDidFinish(outcome: result.outcome, totalTokenUsage: result.totalTokenUsage)
                    return result
                }
            }
        }

        let outcome = AgentOutcome.maxStepsReached
        await stepMonitor?.agentDidFinish(outcome: outcome, totalTokenUsage: cumulativeTokenUsage)
        return AgentResult(
            outcome: outcome,
            steps: steps,
            totalDurationMs: elapsedMs(from: startTime),
            totalTokenUsage: cumulativeTokenUsage,
        )
    }

    // MARK: - Private helpers

    private func processToolCalls(
        toolCalls: [AgentToolCall],
        assistantText: String?,
        stepIndex: Int,
        stepStart: DispatchTime,
        tokenUsage: LLMTokenUsage?,
        accumulatedMessages: inout [AgentMessage],
        steps: [AgentStep],
        totalStart: DispatchTime,
        cumulativeTokenUsage: LLMTokenUsage?,
    ) async throws -> ([AgentStep], AgentResult?) {
        var updatedSteps = steps
        let assistantMsg = AgentAssistantMessage(text: assistantText, toolCalls: toolCalls)
        accumulatedMessages.append(.assistant(assistantMsg))

        // Check for termination tools first
        for toolCall in toolCalls {
            if await toolRegistry.isTerminationTool(name: toolCall.name) {
                let step = AgentStep(
                    stepIndex: stepIndex,
                    assistantMessage: assistantMsg,
                    toolResults: [],
                    durationMs: elapsedMs(from: stepStart),
                    tokenUsage: tokenUsage,
                )
                updatedSteps.append(step)
                await stepMonitor?.agentDidCompleteStep(step)
                let outcome = AgentOutcome.terminationTool(
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON,
                )
                return (updatedSteps, AgentResult(
                    outcome: outcome,
                    steps: updatedSteps,
                    totalDurationMs: elapsedMs(from: totalStart),
                    totalTokenUsage: cumulativeTokenUsage,
                ))
            }
        }

        // Execute non-termination tools
        var toolResults: [AgentToolResult] = []
        if config.allowParallelToolCalls {
            toolResults = try await executeToolsParallel(toolCalls: toolCalls)
        } else {
            for toolCall in toolCalls {
                let result = try await toolRegistry.execute(
                    name: toolCall.name,
                    arguments: toolCall.argumentsJSON,
                    toolCallId: toolCall.id,
                )
                toolResults.append(result)
                accumulatedMessages.append(.toolResult(result))
            }
        }

        if config.allowParallelToolCalls {
            for result in toolResults {
                accumulatedMessages.append(.toolResult(result))
            }
        }

        let step = AgentStep(
            stepIndex: stepIndex,
            assistantMessage: assistantMsg,
            toolResults: toolResults,
            durationMs: elapsedMs(from: stepStart),
            tokenUsage: tokenUsage,
        )
        updatedSteps.append(step)
        await stepMonitor?.agentDidCompleteStep(step)

        return (updatedSteps, nil)
    }

    private func executeToolsParallel(toolCalls: [AgentToolCall]) async throws -> [AgentToolResult] {
        try await withThrowingTaskGroup(of: (Int, AgentToolResult).self) { group in
            for (index, toolCall) in toolCalls.enumerated() {
                group.addTask {
                    let result = try await self.toolRegistry.execute(
                        name: toolCall.name,
                        arguments: toolCall.argumentsJSON,
                        toolCallId: toolCall.id,
                    )
                    return (index, result)
                }
            }
            var indexed: [(Int, AgentToolResult)] = []
            for try await pair in group {
                indexed.append(pair)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func elapsedMs(from start: DispatchTime) -> Int64 {
        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Int64(nanos / 1_000_000)
    }
}
