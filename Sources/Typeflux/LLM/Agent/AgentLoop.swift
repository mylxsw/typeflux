import Foundation

/// AgentLoop — 核心执行引擎
actor AgentLoop {
    private let llmService: LLMMultiTurnService
    private let toolRegistry: AgentToolRegistry
    private let config: AgentConfig
    private var stepMonitor: (any AgentStepMonitor)?

    init(
        llmService: LLMMultiTurnService,
        toolRegistry: AgentToolRegistry,
        config: AgentConfig = .default
    ) {
        self.llmService = llmService
        self.toolRegistry = toolRegistry
        self.config = config
    }

    /// 设置步骤监控器
    func setStepMonitor(_ monitor: (any AgentStepMonitor)?) {
        stepMonitor = monitor
    }

    /// 运行 Agent
    /// - Parameters:
    ///   - messages: 初始消息（通常为 system + user）
    ///   - streamHandler: 流式文本输出回调（可选）
    /// - Returns: Agent 执行结果
    func run(
        messages: [AgentMessage],
        streamHandler: ((String) -> Void)? = nil
    ) async throws -> AgentResult {
        var accumulatedMessages = messages
        var accumulatedText = ""
        var steps: [AgentStep] = []
        let startTime = DispatchTime.now()

        for stepIndex in 0..<config.maxSteps {
            let stepStart = DispatchTime.now()

            let callConfig = LLMCallConfig(
                forcedToolName: nil,
                parallelToolCalls: config.allowParallelToolCalls,
                temperature: config.temperature
            )

            let turn = try await llmService.complete(
                messages: accumulatedMessages,
                tools: await toolRegistry.definitions,
                config: callConfig
            )

            switch turn {
            case .text(let text):
                if !text.isEmpty {
                    accumulatedText += text
                    streamHandler?(text)
                }
                let outcome = AgentOutcome.text(accumulatedText)
                await stepMonitor?.agentDidFinish(outcome: outcome)
                return AgentResult(
                    outcome: outcome,
                    steps: steps,
                    totalDurationMs: elapsedMs(from: startTime)
                )

            case .toolCalls(let toolCalls):
                let (newSteps, terminationResult) = try await processToolCalls(
                    toolCalls: toolCalls,
                    assistantText: nil,
                    stepIndex: stepIndex,
                    stepStart: stepStart,
                    accumulatedMessages: &accumulatedMessages,
                    steps: steps,
                    totalStart: startTime
                )
                steps = newSteps
                if let result = terminationResult {
                    await stepMonitor?.agentDidFinish(outcome: result.outcome)
                    return result
                }

            case .textWithToolCalls(let text, let toolCalls):
                if !text.isEmpty {
                    accumulatedText += text
                    streamHandler?(text)
                }
                let (newSteps, terminationResult) = try await processToolCalls(
                    toolCalls: toolCalls,
                    assistantText: text.isEmpty ? nil : text,
                    stepIndex: stepIndex,
                    stepStart: stepStart,
                    accumulatedMessages: &accumulatedMessages,
                    steps: steps,
                    totalStart: startTime
                )
                steps = newSteps
                if let result = terminationResult {
                    await stepMonitor?.agentDidFinish(outcome: result.outcome)
                    return result
                }
            }
        }

        let outcome = AgentOutcome.maxStepsReached
        await stepMonitor?.agentDidFinish(outcome: outcome)
        return AgentResult(
            outcome: outcome,
            steps: steps,
            totalDurationMs: elapsedMs(from: startTime)
        )
    }

    // MARK: - Private helpers

    private func processToolCalls(
        toolCalls: [AgentToolCall],
        assistantText: String?,
        stepIndex: Int,
        stepStart: DispatchTime,
        accumulatedMessages: inout [AgentMessage],
        steps: [AgentStep],
        totalStart: DispatchTime
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
                    durationMs: elapsedMs(from: stepStart)
                )
                updatedSteps.append(step)
                await stepMonitor?.agentDidCompleteStep(step)
                let outcome = AgentOutcome.terminationTool(
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
                return (updatedSteps, AgentResult(
                    outcome: outcome,
                    steps: updatedSteps,
                    totalDurationMs: elapsedMs(from: totalStart)
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
                    toolCallId: toolCall.id
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
            durationMs: elapsedMs(from: stepStart)
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
                        toolCallId: toolCall.id
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
