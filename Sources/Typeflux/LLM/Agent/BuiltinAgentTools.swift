import Foundation

/// 向用户展示答案的终止工具
struct AnswerTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.answerText.rawValue,
        description: "当用户想要获取关于选中文本的问题答案时使用。在弹窗中向用户展示最终答案。",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.answerText.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("answer")]),
                "properties": .object([
                    "answer": .object([
                        "type": .string("string"),
                        "description": .string("要向用户展示的最终答案"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("markdown"), .string("plain")]),
                    ]),
                ]),
            ]
        )
    )

    func execute(arguments: String) async throws -> String {
        struct Args: Codable { let answer: String; let format: String? }
        guard let data = arguments.data(using: .utf8),
              (try? JSONDecoder().decode(Args.self, from: data)) != nil else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Invalid arguments")
        }
        return arguments
    }
}

/// 替换选中文本的终止工具
struct EditTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.editText.rawValue,
        description: "当用户想要重写、翻译、改写或以其他方式修改选中文本时使用。用新文本替换用户之前选中的文本。",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.editText.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("replacement")]),
                "properties": .object([
                    "replacement": .object([
                        "type": .string("string"),
                        "description": .string("用于替换选中文本的新内容"),
                    ]),
                ]),
            ]
        )
    )

    func execute(arguments: String) async throws -> String {
        return arguments
    }
}

/// 读取剪贴板内容的中间工具
struct GetClipboardTool: AgentTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.getClipboard.rawValue,
        description: "读取当前系统剪贴板的内容。当用户提到「剪贴板里的内容」或需要引用之前复制的内容时使用。",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.getClipboard.rawValue,
            schema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:]),
            ]
        )
    )

    private let clipboardService: ClipboardService

    init(clipboardService: ClipboardService) {
        self.clipboardService = clipboardService
    }

    func execute(arguments: String) async throws -> String {
        guard let content = clipboardService.getString() else {
            return #"{"error": "剪贴板为空或无文本内容"}"#
        }
        let dict: [String: Any] = ["content": content]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? #"{"error": "encoding failed"}"#
    }
}
