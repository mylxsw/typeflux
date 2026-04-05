import Foundation

extension AgentMessage {
    // MARK: - OpenAI Compatible Format

    /// 转换为 OpenAI 兼容格式的消息列表
    static func toOpenAIMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message {
            case let .system(text):
                result.append(["role": "system", "content": text])
            case let .user(text):
                result.append(["role": "user", "content": text])
            case let .assistant(msg):
                if msg.toolCalls.isEmpty {
                    result.append([
                        "role": "assistant",
                        "content": msg.text as Any,
                    ])
                } else {
                    var dict: [String: Any] = [
                        "role": "assistant",
                        "tool_calls": msg.toolCalls.map { tc in
                            [
                                "id": tc.id,
                                "type": "function",
                                "function": [
                                    "name": tc.name,
                                    "arguments": tc.argumentsJSON,
                                ],
                            ] as [String: Any]
                        },
                    ]
                    if let text = msg.text {
                        dict["content"] = text
                    } else {
                        dict["content"] = NSNull()
                    }
                    result.append(dict)
                }
            case let .toolResult(tr):
                result.append([
                    "role": "tool",
                    "tool_call_id": tr.toolCallId,
                    "content": tr.content,
                ])
            }
        }
        return result
    }

    // MARK: - Anthropic Format

    /// 转换为 Anthropic 格式的消息列表
    /// 注意：system 消息应单独提取，不放入 messages 数组
    static func toAnthropicMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system:
                // system 消息在 Anthropic 格式中单独处理，不在 messages 中
                continue
            case let .user(text):
                result.append([
                    "role": "user",
                    "content": [["type": "text", "text": text]],
                ])
            case let .assistant(msg):
                var content: [[String: Any]] = []
                if let text = msg.text, !text.isEmpty {
                    content.append(["type": "text", "text": text])
                }
                for tc in msg.toolCalls {
                    guard let argsData = tc.argumentsJSON.data(using: .utf8),
                          let argsDict = try? JSONSerialization.jsonObject(with: argsData)
                    else {
                        continue
                    }
                    content.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": argsDict,
                    ])
                }
                if !content.isEmpty {
                    result.append(["role": "assistant", "content": content])
                }
            case let .toolResult(tr):
                result.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": tr.toolCallId,
                            "content": tr.content,
                            "is_error": tr.isError,
                        ] as [String: Any],
                    ],
                ])
            }
        }
        return result
    }

    /// 从消息列表中提取 Anthropic system prompt
    static func extractAnthropicSystemPrompt(_ messages: [AgentMessage]) -> String? {
        let systemMessages = messages.compactMap { msg -> String? in
            if case let .system(text) = msg { return text }
            return nil
        }
        return systemMessages.isEmpty ? nil : systemMessages.joined(separator: "\n\n")
    }

    // MARK: - Gemini Format

    /// 转换为 Gemini 格式的 contents 列表
    static func toGeminiContents(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system:
                // system 消息在 Gemini 格式中通过 systemInstruction 处理
                continue
            case let .user(text):
                result.append([
                    "role": "user",
                    "parts": [["text": text]],
                ])
            case let .assistant(msg):
                var parts: [[String: Any]] = []
                if let text = msg.text, !text.isEmpty {
                    parts.append(["text": text])
                }
                for tc in msg.toolCalls {
                    guard let argsData = tc.argumentsJSON.data(using: .utf8),
                          let argsDict = try? JSONSerialization.jsonObject(with: argsData)
                    else {
                        continue
                    }
                    parts.append([
                        "functionCall": [
                            "name": tc.name,
                            "args": argsDict,
                        ],
                    ])
                }
                if !parts.isEmpty {
                    result.append(["role": "model", "parts": parts])
                }
            case let .toolResult(tr):
                // In Gemini, tool results come after a model turn with functionCall
                // They are sent as user role with functionResponse
                result.append([
                    "role": "user",
                    "parts": [
                        [
                            "functionResponse": [
                                "name": tr.toolCallId,
                                "response": [
                                    "content": tr.content,
                                    "isError": tr.isError,
                                ],
                            ],
                        ] as [String: Any],
                    ],
                ])
            }
        }
        return result
    }

    /// 从消息列表中提取 Gemini systemInstruction
    static func extractGeminiSystemInstruction(_ messages: [AgentMessage]) -> [String: Any]? {
        let systemTexts = messages.compactMap { msg -> String? in
            if case let .system(text) = msg { return text }
            return nil
        }
        guard !systemTexts.isEmpty else { return nil }
        return [
            "parts": [["text": systemTexts.joined(separator: "\n\n")]],
        ]
    }
}
