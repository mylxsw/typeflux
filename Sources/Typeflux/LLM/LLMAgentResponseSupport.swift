import Foundation

struct LLMAgentToolCall: Equatable {
    let name: String
    let argumentsJSON: String
}

enum LLMAgentResponseSupport {
    static func openAICompatibleToolBody(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        tools: [LLMAgentTool],
        forcedToolName: String?,
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "parallel_tool_calls": false,
            "tools": tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.jsonObject,
                    ],
                ]
            },
        ]

        if let forcedToolName {
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": forcedToolName],
            ]
        }

        return body
    }

    static func anthropicToolBody(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        tools: [LLMAgentTool],
        forcedToolName: String?,
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userPrompt],
                    ],
                ],
            ],
            "tools": tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.jsonObject,
                ]
            },
        ]

        if let forcedToolName {
            body["tool_choice"] = [
                "type": "tool",
                "name": forcedToolName,
            ]
        }

        return body
    }

    static func geminiToolBody(
        systemPrompt: String,
        userPrompt: String,
        tools: [LLMAgentTool],
        forcedToolName: String?,
    ) -> [String: Any] {
        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userPrompt]],
                ],
            ],
            "generationConfig": [
                "candidateCount": 1,
                "maxOutputTokens": 4096,
            ],
            "tools": [
                [
                    "functionDeclarations": tools.map { tool in
                        [
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": tool.inputSchema.jsonObject,
                        ]
                    },
                ],
            ],
        ]

        if let forcedToolName {
            body["toolConfig"] = [
                "functionCallingConfig": [
                    "mode": "ANY",
                    "allowedFunctionNames": [forcedToolName],
                ],
            ]
        }

        return body
    }

    static func extractOpenAICompatibleToolCall(from data: Data) -> LLMAgentToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let toolCall = (message["tool_calls"] as? [[String: Any]])?.first,
              let function = toolCall["function"] as? [String: Any],
              let name = function["name"] as? String,
              let arguments = function["arguments"] as? String
        else {
            return nil
        }

        return LLMAgentToolCall(name: name, argumentsJSON: arguments)
    }

    static func extractAnthropicToolCall(from data: Data) -> LLMAgentToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let name = toolUse["name"] as? String,
              let input = toolUse["input"],
              JSONSerialization.isValidJSONObject(input),
              let inputData = try? JSONSerialization.data(withJSONObject: input),
              let arguments = String(data: inputData, encoding: .utf8)
        else {
            return nil
        }

        return LLMAgentToolCall(name: name, argumentsJSON: arguments)
    }

    static func extractGeminiToolCall(from data: Data) -> LLMAgentToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        for part in parts {
            guard let functionCall = part["functionCall"] as? [String: Any],
                  let name = functionCall["name"] as? String
            else {
                continue
            }

            let args = functionCall["args"] ?? [:]
            guard JSONSerialization.isValidJSONObject(args),
                  let argsData = try? JSONSerialization.data(withJSONObject: args),
                  let arguments = String(data: argsData, encoding: .utf8)
            else {
                continue
            }

            return LLMAgentToolCall(name: name, argumentsJSON: arguments)
        }

        return nil
    }
}
