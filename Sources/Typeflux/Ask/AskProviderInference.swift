import Foundation

extension AskCustomInference {
    func complete(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration,
                  payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)? = nil, onProgress: (@Sendable (AskStreamProgress) async -> Void)? = nil) async throws -> (String, [AskToolCall]) {
        if connection.provider.apiStyle == .openAICompatible {
            var endpoint = connection.baseURL
            if provider.isOllama, !endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("/v1") {
                endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
            }
            return try await complete(profile: .init(name: provider.name, baseURL: endpoint, model: connection.model),
                                      key: connection.apiKey, payload: payload, onUsage: onUsage, onProgress: onProgress)
        }
        try AskModelProfile(name: provider.name, baseURL: connection.baseURL, model: connection.model).validate()
        guard let body = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let base = URL(string: connection.baseURL) else { throw AskLocalError.message(L("ask.models.invalid")) }
        let anthropic = connection.provider.apiStyle == .anthropic
        var url = anthropic ? OpenAIEndpointResolver.resolve(from: base, path: "messages")
            : base.appendingPathComponent("models/\(connection.model):generateContent")
        if !anthropic, onProgress != nil {
            url = base.appendingPathComponent("models/\(connection.model):streamGenerateContent")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.apiKey, forHTTPHeaderField: anthropic ? "x-api-key" : "x-goog-api-key")
        if anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        var native = try Self.nativeBody(body, model: connection.model, anthropic: anthropic)
        if anthropic, onProgress != nil { native["stream"] = true }
        let effort = AskReasoningRequest.effort(in: body)
        if anthropic {
            AskReasoningRequest.applyAnthropic(effort: effort, to: &native)
        } else {
            AskReasoningRequest.applyGemini(effort: effort, to: &native)
        }
        return try await AskReasoningRequest.send(native) { native in
            request.httpBody = try JSONSerialization.data(withJSONObject: native)
            return try await sendNative(request, anthropic: anthropic, onUsage: onUsage, onProgress: onProgress)
        }
    }

    private func sendNative(_ request: URLRequest, anthropic: Bool, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                            onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        if let onProgress { return try await stream(request, style: anthropic ? .anthropic : .gemini, onUsage: onUsage, onProgress: onProgress) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode),
              data.count <= 2_000_000 else {
            if let status = (response as? HTTPURLResponse)?.statusCode, AskReasoningRequest.isRejection(status: status) {
                throw AskStreamError.rejected
            }
            throw AskLocalError.message(L("ask.models.requestError"))
        }
        if let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = AskTokenUsage.parse(body, style: anthropic ? .anthropic : .gemini) { await onUsage?(usage) }
        return try Self.nativeReply(data, anthropic: anthropic)
    }

    /// Translate the bridge's OpenAI messages without dropping image or tool-result context.
    static func nativeBody(_ body: [String: Any], model: String, anthropic: Bool) throws -> [String: Any] {
        guard let messages = body["messages"] as? [[String: Any]]
        else { throw AskLocalError.message(L("models.invalidResponse")) }
        var system: [String] = []
        var output: [[String: Any]] = []
        var names: [String: String] = [:]
        for message in messages {
            let role = message["role"] as? String ?? "user"
            if role == "system" || role == "developer" {
                if let text = message["content"] as? String {
                    system.append(text)
                }
                continue
            }
            let parts = try nativeParts(message, anthropic: anthropic, names: &names)
            let nativeRole = role == "assistant" ? (anthropic ? "assistant" : "model") : "user"
            let field = anthropic ? "content" : "parts"
            // Consecutive tool results form a single user turn for both native APIs.
            if output.last?["role"] as? String == nativeRole, var last = output.popLast() {
                last[field] = (last[field] as? [[String: Any]] ?? []) + parts
                output.append(last)
            } else {
                output.append(["role": nativeRole, field: parts])
            }
        }
        let functions = (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["function"] as? [String: Any] }
        if anthropic {
            var result: [String: Any] = ["model": model, "max_tokens": body["max_tokens"] ?? 4096, "messages": output]
            if !system.isEmpty {
                result["system"] = system.joined(separator: "\n\n")
            }
            if !functions.isEmpty {
                result["tools"] = functions.map { [
                    "name": $0["name"] ?? "",
                    "description": $0["description"] ?? "",
                    "input_schema": $0["parameters"] ?? [:]
                ] }
            }
            return result
        }
        var result: [String: Any] = ["contents": output]
        if !system.isEmpty {
            result["systemInstruction"] = ["parts": [["text": system.joined(separator: "\n\n")]]]
        }
        if !functions.isEmpty {
            result["tools"] = [["functionDeclarations": functions.map { function in
                ["name": function["name"] ?? "", "description": function["description"] ?? "",
                 "parameters": function["parameters"] ?? [:]]
            }]]
        }
        return result
    }

    private static func nativeParts(_ message: [String: Any], anthropic: Bool,
                                    names: inout [String: String]) throws -> [[String: Any]] {
        if message["role"] as? String == "tool" {
            let id = message["tool_call_id"] as? String ?? ""
            let text = message["content"] as? String ?? ""
            return anthropic ? [["type": "tool_result", "tool_use_id": id, "content": text]]
                : [["functionResponse": ["name": names[id] ?? id, "response": ["content": text]]]]
        }
        var parts: [[String: Any]] = []
        if let text = message["content"] as? String,
           !text.isEmpty {
            parts.append(textPart(text, anthropic: anthropic))
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            if let text = block["text"] as? String {
                parts.append(textPart(text, anthropic: anthropic))
            } else {
                try parts.append(imagePart(block, anthropic: anthropic))
            }
        }
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            try parts.append(toolPart(call, anthropic: anthropic, names: &names))
        }
        return parts
    }

    private static func imagePart(_ block: [String: Any], anthropic: Bool) throws -> [String: Any] {
        guard let image = block["image_url"] as? [String: Any], let url = image["url"] as? String,
              url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), let semicolon = url.firstIndex(of: ";"),
              semicolon < comma else { throw AskLocalError.message(L("models.invalidResponse")) }
        let mime = String(url[url.index(url.startIndex, offsetBy: 5) ..< semicolon])
        let data = String(url[url.index(after: comma)...])
        return anthropic ? ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data]]
            : ["inlineData": ["mimeType": mime, "data": data]]
    }

    private static func toolPart(_ call: [String: Any], anthropic: Bool,
                                 names: inout [String: String]) throws -> [String: Any] {
        guard let function = call["function"] as? [String: Any], let name = function["name"] as? String,
              let arguments = function["arguments"] as? String, let id = call["id"] as? String else {
            throw AskLocalError.message(L("models.invalidResponse"))
        }
        let input = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        names[id] = name
        if anthropic {
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        }
        var part: [String: Any] = ["functionCall": ["name": name, "args": input]]
        if let signature = call["thought_signature"] as? String {
            part["thoughtSignature"] = signature
        }
        return part
    }

    private static func textPart(_ text: String, anthropic: Bool) -> [String: Any] {
        anthropic ? ["type": "text", "text": text] : ["text": text]
    }

    static func nativeReply(_ data: Data, anthropic: Bool) throws -> (String, [AskToolCall]) {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AskLocalError.message(L("models.invalidResponse")) }
        let parts: [[String: Any]]
        if anthropic {
            parts = body["content"] as? [[String: Any]] ?? []
        } else {
            let candidates = body["candidates"] as? [[String: Any]] ?? []
            parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        }
        var text = ""
        var calls: [AskToolCall] = []
        for part in parts {
            if let value = part["text"] as? String, part["thought"] as? Bool != true {
                text += value
            }
            let call = anthropic ? (part["type"] as? String == "tool_use" ? part : nil) :
                part["functionCall"] as? [String: Any]
            if let call, let name = call["name"] as? String {
                let input = call[anthropic ? "input" : "args"] ?? [:]
                let data = try JSONSerialization.data(withJSONObject: input)
                let arguments = String(data: data, encoding: .utf8) ?? "{}"
                let id = call["id"] as? String ?? UUID().uuidString
                calls.append(.init(id: id, type: "function", function: .init(name: name, arguments: arguments),
                                   thoughtSignature: anthropic ? nil : part["thoughtSignature"] as? String))
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { throw AskLocalError.message(L("ask.models.requestError")) }
        return (text, calls)
    }
}
