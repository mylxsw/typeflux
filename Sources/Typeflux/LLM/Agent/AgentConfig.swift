import Foundation

/// Agent 配置
struct AgentConfig: Sendable {
    /// 最大执行步数（默认 10）
    let maxSteps: Int
    /// 是否允许 LLM 并行调用多个工具（默认 false）
    let allowParallelToolCalls: Bool
    /// 温度参数
    let temperature: Double?
    /// 是否启用流式输出回调
    let enableStreaming: Bool

    static let `default` = AgentConfig(
        maxSteps: 10,
        allowParallelToolCalls: false,
        temperature: nil,
        enableStreaming: false
    )
}
