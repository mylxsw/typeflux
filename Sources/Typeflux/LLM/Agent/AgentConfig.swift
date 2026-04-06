import Foundation

/// Agent configuration.
struct AgentConfig {
    /// Maximum execution steps (default: 10).
    let maxSteps: Int
    /// Whether to allow the LLM to call multiple tools in parallel (default: false).
    let allowParallelToolCalls: Bool
    /// Temperature parameter.
    let temperature: Double?
    /// Whether to enable streaming output callbacks.
    let enableStreaming: Bool
    /// Starting step index offset (default: 0). Use 1 when a Phase 1 step has already been
    /// recorded as step 0, so Phase 2 steps are numbered starting from 1.
    let initialStepIndex: Int

    init(
        maxSteps: Int,
        allowParallelToolCalls: Bool,
        temperature: Double?,
        enableStreaming: Bool,
        initialStepIndex: Int = 0,
    ) {
        self.maxSteps = maxSteps
        self.allowParallelToolCalls = allowParallelToolCalls
        self.temperature = temperature
        self.enableStreaming = enableStreaming
        self.initialStepIndex = initialStepIndex
    }

    static let `default` = AgentConfig(
        maxSteps: 10,
        allowParallelToolCalls: false,
        temperature: nil,
        enableStreaming: false,
        initialStepIndex: 0,
    )
}
