import Foundation

/// Termination reasons for agent execution.
enum AgentOutcome {
    /// The model returned text directly (no tool call).
    case text(String)
    /// A termination tool was called.
    case terminationTool(name: String, argumentsJSON: String)
    /// Maximum steps were reached.
    case maxStepsReached
    /// Execution failed.
    case error(Error)
}

/// Record for a single execution step.
struct AgentStep {
    let stepIndex: Int
    let assistantMessage: AgentAssistantMessage
    let toolResults: [AgentToolResult]
    let durationMs: Int64
    let tokenUsage: LLMTokenUsage?

    init(
        stepIndex: Int,
        assistantMessage: AgentAssistantMessage,
        toolResults: [AgentToolResult],
        durationMs: Int64,
        tokenUsage: LLMTokenUsage? = nil,
    ) {
        self.stepIndex = stepIndex
        self.assistantMessage = assistantMessage
        self.toolResults = toolResults
        self.durationMs = durationMs
        self.tokenUsage = tokenUsage
    }
}

/// Step monitor protocol.
protocol AgentStepMonitor: AnyObject, Sendable {
    /// Called after each step finishes.
    func agentDidCompleteStep(_ step: AgentStep) async
    /// Called when the agent finishes, where totalTokenUsage is cumulative across the whole run.
    func agentDidFinish(outcome: AgentOutcome, totalTokenUsage: LLMTokenUsage?) async
}

/// Real-time state for UI display.
struct AgentRealtimeState {
    let currentStep: Int
    let lastToolCall: AgentToolCall?
    let accumulatedText: String
    let toolCallsSoFar: [AgentToolCall]
}

/// Simple logging step monitor.
final class AgentStepLogger: AgentStepMonitor {
    func agentDidCompleteStep(_ step: AgentStep) async {
        let toolNames = step.assistantMessage.toolCalls.map(\.name).joined(separator: ", ")
        let tokenInfo = step.tokenUsage.map { " tokens=\($0.totalTokens)" } ?? ""
        print("[AgentStepLogger] Step \(step.stepIndex): tools=[\(toolNames)], duration=\(step.durationMs)ms\(tokenInfo)")
    }

    func agentDidFinish(outcome: AgentOutcome, totalTokenUsage: LLMTokenUsage?) async {
        let tokenInfo = totalTokenUsage.map { " totalTokens=\($0.totalTokens)" } ?? ""
        switch outcome {
        case let .text(text):
            print("[AgentStepLogger] Finished with text: \(text.prefix(80))\(tokenInfo)")
        case let .terminationTool(name, _):
            print("[AgentStepLogger] Finished with termination tool: \(name)\(tokenInfo)")
        case .maxStepsReached:
            print("[AgentStepLogger] Finished: max steps reached\(tokenInfo)")
        case let .error(error):
            print("[AgentStepLogger] Finished with error: \(error)\(tokenInfo)")
        }
    }
}
