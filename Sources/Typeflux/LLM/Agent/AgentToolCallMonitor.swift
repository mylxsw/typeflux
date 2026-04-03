import Foundation

/// Agent 执行的终止原因
enum AgentOutcome: Sendable {
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
struct AgentStep: Sendable {
    let stepIndex: Int
    let assistantMessage: AgentAssistantMessage
    let toolResults: [AgentToolResult]
    let durationMs: Int64
}

/// 步骤监控器协议
protocol AgentStepMonitor: AnyObject, Sendable {
    /// 每一步执行完成后调用
    func agentDidCompleteStep(_ step: AgentStep) async
    /// Agent 完成后调用
    func agentDidFinish(outcome: AgentOutcome) async
}

/// 用于 UI 展示的实时状态
struct AgentRealtimeState: Sendable {
    let currentStep: Int
    let lastToolCall: AgentToolCall?
    let accumulatedText: String
    let toolCallsSoFar: [AgentToolCall]
}

/// 简单的日志步骤监控器
final class AgentStepLogger: AgentStepMonitor {
    func agentDidCompleteStep(_ step: AgentStep) async {
        let toolNames = step.assistantMessage.toolCalls.map(\.name).joined(separator: ", ")
        print("[AgentStepLogger] Step \(step.stepIndex): tools=[\(toolNames)], duration=\(step.durationMs)ms")
    }

    func agentDidFinish(outcome: AgentOutcome) async {
        switch outcome {
        case .text(let text):
            print("[AgentStepLogger] Finished with text: \(text.prefix(80))")
        case .terminationTool(let name, _):
            print("[AgentStepLogger] Finished with termination tool: \(name)")
        case .maxStepsReached:
            print("[AgentStepLogger] Finished: max steps reached")
        case .error(let error):
            print("[AgentStepLogger] Finished with error: \(error)")
        }
    }
}
