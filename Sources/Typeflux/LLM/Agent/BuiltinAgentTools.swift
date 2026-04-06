import Foundation

/// Termination tool for presenting an answer to the user.
struct AnswerTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.answerText.rawValue,
        description: "Use when the user asks a question about selected text and expects an answer. Present the final answer in a popup window.",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.answerText.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("answer")]),
                "properties": .object([
                    "answer": .object([
                        "type": .string("string"),
                        "description": .string("Final answer to show to the user"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("markdown"), .string("plain")]),
                    ]),
                ]),
            ],
        ),
    )

    func execute(arguments: String) async throws -> String {
        struct Args: Codable { let answer: String; let format: String? }
        guard let data = arguments.data(using: .utf8),
              (try? JSONDecoder().decode(Args.self, from: data)) != nil
        else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Invalid arguments")
        }
        return arguments
    }
}

/// Termination tool for replacing selected text.
struct EditTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.editText.rawValue,
        description: "Use when the user wants to rewrite, translate, rephrase, or otherwise modify selected text. Replace the previously selected text with new content.",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.editText.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("replacement")]),
                "properties": .object([
                    "replacement": .object([
                        "type": .string("string"),
                        "description": .string("New content to replace the selected text"),
                    ]),
                ]),
            ],
        ),
    )

    func execute(arguments: String) async throws -> String {
        arguments
    }
}

/// Phase 1 termination tool that delegates execution to the full agent loop.
/// The model uses this when the task requires multiple steps, external tool calls,
/// or complex reasoning that cannot be completed in a single response.
struct RunAgentTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.runAgent.rawValue,
        description: "Delegate to the full agent loop when the task requires multiple steps, external tool access (files, clipboard, web), or complex reasoning that cannot be completed in one response. Rewrite the user's intent into a precise, unambiguous, and actionable instruction for the agent.",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.runAgent.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("detailed_instruction")]),
                "properties": .object([
                    "detailed_instruction": .object([
                        "type": .string("string"),
                        "description": .string("A clarified, precise restatement of the user's goal — unambiguous and directly actionable by the agent. Resolve any implicit assumptions and specify the expected output if relevant."),
                    ]),
                ]),
            ],
        ),
    )

    func execute(arguments: String) async throws -> String {
        arguments
    }
}

/// Intermediate tool for reading clipboard content.
struct GetClipboardTool: AgentTool {
    let definition = LLMAgentTool(
        name: BuiltinAgentToolName.getClipboard.rawValue,
        description: "Read the current system clipboard content. Use when the user refers to clipboard content or needs to reference previously copied text.",
        inputSchema: LLMJSONSchema(
            name: BuiltinAgentToolName.getClipboard.rawValue,
            schema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:]),
            ],
        ),
    )

    private let clipboardService: ClipboardService

    init(clipboardService: ClipboardService) {
        self.clipboardService = clipboardService
    }

    func execute(arguments _: String) async throws -> String {
        guard let content = clipboardService.getString() else {
            return #"{"error": "Clipboard is empty or does not contain text"}"#
        }
        let dict: [String: Any] = ["content": content]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? #"{"error": "encoding failed"}"#
    }
}
