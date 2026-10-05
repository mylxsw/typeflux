import Foundation

/// Wire conversion shared by rewrite, agent tools and Ask. No conversation state
/// is stored at the provider; native output items travel with tool continuations.
enum ResponsesAPI {
    static func body(_ source: [String: Any], model: String) throws -> [String: Any] {
        guard let messages = source["messages"] as? [[String: Any]] else { throw AskStreamError.invalidResponse }
        let input = try messages.flatMap(inputItems)
        var result: [String: Any] = ["model": model, "input": input, "store": false,
                                     "include": ["reasoning.encrypted_content"], "stream": source["stream"] ?? false]
        for name in ["temperature", "top_p", "parallel_tool_calls"] {
            result[name] = source[name]
        }
        result["max_output_tokens"] = source["max_completion_tokens"] ?? source["max_tokens"]
        if let effort = source["reasoning_effort"] as? String,
           !effort.isEmpty {
            result["reasoning"] = ["effort": effort]
        }
        if let tools = source["tools"] as? [[String: Any]], !tools.isEmpty {
            result["tools"] = try tools.map { tool -> [String: Any] in
                guard tool["type"] as? String == "function", var function = tool["function"] as? [String: Any] else {
                    throw AskStreamError.invalidResponse
                }
                function["type"] = "function"
                function["strict"] = function["strict"] ?? false
                return function
            }
        }
        if let choice = source["tool_choice"] as? String {
            result["tool_choice"] = choice
        }
        if let choice = source["tool_choice"] as? [String: Any], let function = choice["function"] as? [String: Any],
           let name = function["name"] as? String {
            result["tool_choice"] = ["type": "function", "name": name]
        }
        if let format = source["response_format"] as? [String: Any] {
            if format["type"] as? String == "json_schema", var schema = format["json_schema"] as? [String: Any] {
                schema["type"] = "json_schema"; result["text"] = ["format": schema]
            } else {
                result["text"] = ["format": format]
            }
        }
        return result
    }

    private static func inputItems(_ message: [String: Any]) throws -> [[String: Any]] {
        guard let role = message["role"] as? String else { throw AskStreamError.invalidResponse }
        if role == "assistant", let context = try ProviderContinuation.restore(message, protocolName: "responses") {
            return context
        }
        if role == "tool" {
            guard let id = message["tool_call_id"] as? String, let text = message["content"] as? String else {
                throw AskStreamError.invalidResponse
            }
            return [["type": "function_call_output", "call_id": id, "output": text]]
        }
        guard ["system", "developer", "user", "assistant"].contains(role) else { throw AskStreamError.invalidResponse }
        let content = try contentParts(message["content"])
        var input: [[String: Any]] = content.isEmpty ? [] : [["role": role, "content": content]]
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String, let arguments = function["arguments"] as? String else {
                throw AskStreamError.invalidResponse
            }
            input.append(["type": "function_call", "call_id": id, "name": name, "arguments": arguments])
        }
        return input
    }

    private static func contentParts(_ value: Any?) throws -> [[String: Any]] {
        if let text = value as? String {
            return text.isEmpty ? [] : [["type": "input_text", "text": text]]
        }
        return try (value as? [[String: Any]] ?? []).map { part in
            if part["type"] as? String == "text", let text = part["text"] as? String {
                return ["type": "input_text", "text": text]
            }
            if part["type"] as? String == "image_url", let image = part["image_url"] as? [String: Any],
               let url = image["url"] as? String {
                return ["type": "input_image", "image_url": url, "detail": image["detail"] ?? "auto"]
            }
            throw AskStreamError.invalidResponse
        }
    }

    static func reply(_ body: [String: Any], allowIncomplete: Bool = false) throws -> (String, [AskToolCall]) {
        let status = body["status"] as? String
        guard body["error"] == nil || body["error"] is NSNull,
              status == nil || status == "completed" || (allowIncomplete && status == "incomplete"),
              let items = body["output"] as? [[String: Any]] else { throw AskStreamError.invalidResponse }
        var text = ""
        var calls: [AskToolCall] = []
        for item in items {
            if item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                    text += part["text"] as? String ?? ""
                }
            } else if item["type"] as? String == "function_call" {
                guard let id = item["call_id"] as? String, !id.isEmpty, let name = item["name"] as? String,
                      !name.isEmpty,
                      let args = item["arguments"] as? String, args.utf8.count <= 64000,
                      (try? JSONSerialization.jsonObject(with: Data(args.utf8))) is [String: Any] else {
                    throw AskStreamError.invalidResponse
                }
                calls.append(.init(id: id, type: "function", function: .init(name: name, arguments: args)))
            }
        }
        guard text.utf8.count <= 256_000, calls.count <= 8, !text.isEmpty || !calls.isEmpty,
              status != "incomplete" || calls.isEmpty else { throw AskStreamError.invalidResponse }
        if !calls
            .isEmpty {
            calls[0].providerContext = try ProviderContinuation.encode(items, protocolName: "responses")
        }
        return (text, calls)
    }
}

enum ProviderContinuation {
    static func encode(_ items: [[String: Any]], protocolName: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["protocol": protocolName, "blocks": items])
        guard data.count <= 256_000 else { throw AskStreamError.invalidResponse }
        guard let value = String(data: data, encoding: .utf8) else { throw AskStreamError.invalidResponse }
        return value
    }

    static func restore(_ message: [String: Any], protocolName: String) throws -> [[String: Any]]? {
        guard let calls = message["tool_calls"] as? [[String: Any]],
              let value = calls.first?["provider_context"] as? String else { return nil }
        guard value.utf8.count <= 256_000,
              let context = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw AskStreamError.invalidResponse
        }
        guard context["protocol"] as? String == protocolName else { return nil }
        guard let blocks = context["blocks"] as? [[String: Any]],
              !blocks.isEmpty else { throw AskStreamError.invalidResponse }
        return blocks
    }
}
