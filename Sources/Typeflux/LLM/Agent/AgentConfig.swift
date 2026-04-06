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

    static let `default` = AgentConfig(
        maxSteps: 10,
        allowParallelToolCalls: false,
        temperature: nil,
        enableStreaming: false,
    )
}
