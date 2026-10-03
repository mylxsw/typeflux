import Foundation
import CoreFoundation

/// Adapter from MCP tools to AgentTool.
struct MCPToolAdapter: AgentTool {
    let client: any MCPClient
    let toolDef: MCPToolDefinition

    var definition: LLMAgentTool {
        LLMAgentTool(
            name: toolDef.name,
            description: toolDef.description ?? "",
            inputSchema: convertSchema(toolDef.inputSchema)
        )
    }

    /// Calls the tool and keeps the MCP error flag and non-text content.
    func call(arguments: String) async throws -> MCPToolsCallResult {
        let args = try MCPInputValidator.validate(arguments: arguments, schema: toolDef.inputSchema)
        return try await client.callTool(name: toolDef.name, arguments: args)
    }

    func execute(arguments: String) async throws -> String {
        let result = try await call(arguments: arguments)
        let output = AskTypedContent.output(from: result)
        let content = output.content

        let dict: [String: Any] = if output.isError {
            ["error": content]
        } else {
            ["result": content]
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private

    private func convertSchema(_ mcpSchema: MCPObjectSchema) -> LLMJSONSchema {
        LLMJSONSchema(name: toolDef.name, schema: mcpSchema.raw.mapValues(convertAnyCodable), strict: false)
    }

    private func convertAnyCodable(_ value: AnyCodable) -> AnySendable {
        switch value.value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if ["f", "d"].contains(String(cString: number.objCType)) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let str as String:
            return .string(str)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { convertAnyCodable(AnyCodable($0)) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { convertAnyCodable(AnyCodable($0)) })
        default:
            return .null
        }
    }
}
