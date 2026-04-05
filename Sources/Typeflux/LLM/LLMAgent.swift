import Foundation

struct LLMAgentTool: Sendable {
    let name: String
    let description: String
    let inputSchema: LLMJSONSchema
}

struct LLMAgentRequest: Sendable {
    let systemPrompt: String
    let userPrompt: String
    let tools: [LLMAgentTool]
    let forcedToolName: String?

    init(
        systemPrompt: String,
        userPrompt: String,
        tools: [LLMAgentTool],
        forcedToolName: String? = nil,
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.tools = tools
        self.forcedToolName = forcedToolName
    }
}

enum LLMAgentError: LocalizedError, Equatable {
    case unsupportedProvider
    case noToolsConfigured
    case missingToolCall
    case unexpectedToolName(expected: String?, actual: String)
    case invalidToolArguments

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "The selected model provider does not support agent tool calls."
        case .noToolsConfigured:
            return "No agent tools were configured."
        case .missingToolCall:
            return "The model did not return a tool call."
        case let .unexpectedToolName(expected, actual):
            if let expected {
                return "Unexpected tool call '\(actual)'; expected '\(expected)'."
            }
            return "Unexpected tool call '\(actual)'."
        case .invalidToolArguments:
            return "The model returned invalid tool arguments."
        }
    }
}

protocol LLMAgentService {
    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding type: T.Type) async throws -> T
}
