import Foundation

/// Agent 执行的终止原因
enum AgentOutcome {
    /// 模型直接返回文本（无工具调用）
    case text(String)
    /// 调用了终止工具
    case terminationTool(name: String, argumentsJSON: String)
    /// 达到最大步数
    case maxStepsReached
    /// 执行出错
    case error(Error)
}

/// 单个执行步骤的记录
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

/// 步骤监控器协议
protocol AgentStepMonitor: AnyObject, Sendable {
    /// 每一步执行完成后调用
    func agentDidCompleteStep(_ step: AgentStep) async
    /// Agent 完成后调用，totalTokenUsage 为全程累计 token 用量
    func agentDidFinish(outcome: AgentOutcome, totalTokenUsage: LLMTokenUsage?) async
}

/// 用于 UI 展示的实时状态
struct AgentRealtimeState {
    let currentStep: Int
    let lastToolCall: AgentToolCall?
    let accumulatedText: String
    let toolCallsSoFar: [AgentToolCall]
}

/// 简单的日志步骤监控器
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
