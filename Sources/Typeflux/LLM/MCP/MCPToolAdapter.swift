import Foundation

/// Adapter from MCP tools to AgentTool.
struct MCPToolAdapter: AgentTool {
    let client: any MCPClient
    let toolDef: MCPToolDefinition

    var definition: LLMAgentTool {
        LLMAgentTool(
            name: toolDef.name,
            description: toolDef.description ?? "",
            inputSchema: convertSchema(toolDef.inputSchema),
        )
    }

    func execute(arguments: String) async throws -> String {
        let args: [String: Any] = if let data = arguments.data(using: .utf8),
                                     let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            dict
        } else {
            [:]
        }

        let result = try await client.callTool(name: toolDef.name, arguments: args)
        let content = result.content.map { $0.text ?? "" }.joined(separator: "\n")

        let dict: [String: Any] = if result.isError == true {
            ["error": content]
        } else {
            ["result": content]
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private

    private func convertSchema(_ mcpSchema: MCPObjectSchema) -> LLMJSONSchema {
        var schema: [String: AnySendable] = [
            "type": .string("object"),
        ]

        if let properties = mcpSchema.properties {
            var propsDict: [String: AnySendable] = [:]
            for (key, value) in properties {
                propsDict[key] = convertAnyCodable(value)
            }
            schema["properties"] = .object(propsDict)
        }

        if let required = mcpSchema.required {
            schema["required"] = .array(required.map { .string($0) })
        }

        return LLMJSONSchema(name: toolDef.name, schema: schema, strict: false)
    }

    private func convertAnyCodable(_ value: AnyCodable) -> AnySendable {
        switch value.value {
        case let str as String:
            .string(str)
        case let int as Int:
            .int(int)
        case let double as Double:
            .double(double)
        case let bool as Bool:
            .bool(bool)
        case let array as [Any]:
            .array(array.map { convertAnyCodable(AnyCodable($0)) })
        case let dict as [String: Any]:
            .object(dict.mapValues { convertAnyCodable(AnyCodable($0)) })
        default:
            .null
        }
    }
}
