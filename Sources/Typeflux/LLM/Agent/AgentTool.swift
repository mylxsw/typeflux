import Foundation

/// Agent 工具协议
protocol AgentTool: Sendable {
    /// 工具定义（名称、描述、输入 Schema）
    var definition: LLMAgentTool { get }
    /// 执行工具
    /// - Parameter arguments: JSON 字符串参数
    /// - Returns: 执行结果（文本或 JSON 字符串）
    func execute(arguments: String) async throws -> String
}

/// 终止工具标记协议
protocol TerminationTool: AgentTool {}

/// 内置工具标识
enum BuiltinAgentToolName: String, CaseIterable {
    case answerText = "answer_text"
    case editText = "edit_text"
    case getClipboard = "get_clipboard"
}
