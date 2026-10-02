import Foundation

struct AskInference: Codable, Equatable, Sendable {
    var id: String
    var payload: String
    var summaryThrough: Int?
}

struct AskInferenceResult: Codable, Equatable, Sendable {
    var runId: String
    var deviceId: String
    var inferenceId: String
    var content: String
    var toolCalls: [AskToolCall] = []
    var usage: AskTokenUsage? = nil
    var failed = false
    var reasoning: String? = nil
    var reasoningMilliseconds: Int? = nil
    /// "length" when the provider stopped at its output limit.
    var finishReason: String? = nil
}

/// Refuse redirects so a configured endpoint cannot forward credentials to another host.
final class AskModelRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask,
                    willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AskCustomInference: Sendable {
    var session: URLSession = .init(configuration: .ephemeral, delegate: AskModelRedirectPolicy(), delegateQueue: nil)

    func complete(profile: AskModelProfile, key: String, payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)? = nil, onProgress: (@Sendable (AskStreamProgress) async -> Void)? = nil) async throws -> (String, [AskToolCall]) {
        try profile.validate()
        guard var body = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let base = URL(string: profile.baseURL) else { throw AskLocalError.message(L("ask.models.invalid")) }
        if let messages = body["messages"] as? [[String: Any]] {
            body["messages"] = messages.map { message in
                var message = message
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    message["tool_calls"] = calls.map { call in
                        var call = call
                        call.removeValue(forKey: "thought_signature")
                        return call
                    }
                }
                return message
            }
        }
        body["model"] = profile.model
        body["stream"] = onProgress != nil
        if onProgress != nil { body["stream_options"] = ["include_usage": true] }
        let url = OpenAIEndpointResolver.resolve(from: base, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return try await AskReasoningRequest.send(body) { body in
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await send(request, onUsage: onUsage, onProgress: onProgress)
        }
    }

    private func send(_ request: URLRequest, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                      onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        if let onProgress { return try await stream(request, style: .openAI, onUsage: onUsage, onProgress: onProgress) }
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
           let usage = AskTokenUsage.parse(body, style: .openAI) { await onUsage?(usage) }
        guard let message = try AskCoding.decoder().decode(AskChatReply.self, from: data).choices.first?.message,
              !(message.content ?? "").isEmpty || !(message.toolCalls ?? []).isEmpty else {
            throw AskLocalError.message(L("ask.models.requestError"))
        }
        return (message.content ?? "", message.toolCalls ?? [])
    }

    func test(profile: AskModelProfile, key: String) async throws {
        _ = try await complete(
            profile: profile,
            key: key,
            payload: #"{"messages":[{"role":"user","content":"Reply OK"}],"max_tokens":16}"#
        )
    }
}

private struct AskChatReply: Decodable {
    struct Message: Decodable {
        var content: String?
        var toolCalls: [AskToolCall]?
    }
    struct Choice: Decodable { var message: Message }
    var choices: [Choice]
}
