import Foundation

enum ResponsesLLMClient {
    static func request(baseURL: URL, model: String, apiKey: String, headers: [String: String] = [:],
                        body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: OpenAIEndpointResolver.resolve(from: baseURL, path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ResponsesAPI.body(body, model: model))
        return request
    }

    static func complete(baseURL: URL, model: String, apiKey: String, headers: [String: String],
                         body: [String: Any],
                         session: URLSession = AskCustomInference().session) async throws -> (String, [AskToolCall]) {
        let request = try request(baseURL: baseURL, model: model, apiKey: apiKey, headers: headers, body: body)
        let data = try await RemoteLLMClient.performJSONRequest(request, session: session)
        try Task.checkCancellation()
        guard data.count <= 2_000_000,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskStreamError.invalidResponse
        }
        return try ResponsesAPI.reply(response)
    }

    static func textBody(system: String, user: String, schema: LLMJSONSchema? = nil) -> [String: Any] {
        var body: [String: Any] = ["messages": [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]]
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.name, "schema": schema.jsonObject, "strict": schema.strict]
            ]
        }
        return body
    }

    // Match the remote-client transport interface while allowing an isolated test session.
    // swiftlint:disable:next function_parameter_count
    static func stream(baseURL: URL, model: String, apiKey: String, headers: [String: String],
                       system: String, user: String, continuation: AsyncThrowingStream<String, Error>.Continuation,
                       session: URLSession = AskCustomInference().session) async throws -> String {
        var body = textBody(system: system, user: user); body["stream"] = true
        let request = try request(baseURL: baseURL, model: model, apiKey: apiKey, headers: headers, body: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else { throw AskStreamError.requestFailed }
        var frame = AskSSEFrame()
        var parser = ResponsesStream()
        var emitted = ""
        for try await byte in bytes {
            try Task.checkCancellation()
            if let (_, data) = try frame.push(byte) {
                try parser.consume(data)
                let text = parser.progress.text
                if text.hasPrefix(emitted),
                   text.count > emitted
                   .count {
                    continuation.yield(String(text.dropFirst(emitted.count))); emitted = text
                }
                if parser.finished {
                    break
                }
            }
        }
        guard parser.finished, !parser.progress.truncated else { throw AskStreamError.invalidResponse }
        return try parser.result().0
    }
}

extension AskCustomInference {
    func completeResponses(connection: SettingsStore.TextLLMConfiguration, payload: String,
                           onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                           onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws
        -> (String, [AskToolCall]) {
        try AskModelProfile(name: "Responses", baseURL: connection.baseURL, model: connection.model).validate()
        guard var body = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let base = URL(string: connection.baseURL) else { throw AskStreamError.invalidResponse }
        let bounded = body["typeflux_budget"] as? Bool == true
        let deadline = body["typeflux_deadline"] as? Double
        if bounded, let deadline, Date().timeIntervalSince1970 >= deadline {
            throw AskBudgetError.reached("duration")
        }
        body["stream"] = onProgress != nil
        var request = try ResponsesLLMClient.request(
            baseURL: base,
            model: connection.model,
            apiKey: connection.apiKey,
            body: body
        )
        if bounded {
            request.timeoutInterval = min(
                180,
                max(0.1, (deadline ?? Date().timeIntervalSince1970 + 180) - Date().timeIntervalSince1970)
            )
        }
        if let onProgress {
            return try await stream(request, style: .responses, onUsage: onUsage, onProgress: onProgress)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode),
              data.count <= 2_000_000,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AskStreamError.requestFailed }
        if let usage = AskTokenUsage.parse(result, style: .responses) {
            await onUsage?(usage)
        }
        return try ResponsesAPI.reply(result)
    }
}
