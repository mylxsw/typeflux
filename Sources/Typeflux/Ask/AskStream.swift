import Foundation
import TypefluxChat

enum AskStreamError: Error {
    case invalidResponse, requestFailed
    /// The provider refused the request itself (HTTP 400/422), e.g. an unsupported parameter.
    case rejected
}

struct AskStreamProgress: Equatable, Sendable {
    var text = ""
    var reasoning = ""
    var toolCalls: [AskToolCall] = []
    var reasoningMilliseconds = 0
    var usage: AskTokenUsage? = nil
    /// The provider stopped at its output limit; the answer is incomplete.
    var truncated = false
}

/// Keep desktop error semantics while sharing the framing implementation.
struct AskSSEFrame {
    private var frame: SSEFrame
    var event: String { frame.event }
    var data: String { frame.data }
    init(limit: Int = 2_000_000) { frame = SSEFrame(limit: limit) }
    mutating func push(_ byte: UInt8) throws -> (String, String)? {
        do { return try frame.push(byte) }
        catch { throw AskStreamError.invalidResponse }
    }
    mutating func append(_ line: String) throws -> (String, String)? {
        do { return try frame.append(line) }
        catch { throw AskStreamError.invalidResponse }
    }
}

struct AskProviderStream {
    enum Style { case openAI, anthropic, gemini, responses }
    var style: Style
    private(set) var progress = AskStreamProgress()
    private(set) var finished = false
    private var calls: [Int: AskToolCall] = [:]
    private var responses = ResponsesStream()
    private var nativeBlocks: [Int: [String: Any]] = [:]
    private var emptyArgumentPrefixes: [Int: Int] = [:]

    init(style: Style) { self.style = style }

    mutating func consume(_ data: String) throws {
        if style == .responses {
            try responses.consume(data); progress = responses.progress; finished = responses.finished
            return
        }
        if data == "[DONE]" {
            guard style == .openAI else { throw invalid() }
            finished = true; return
        }
        guard let body = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              body["error"] == nil else { throw AskStreamError.invalidResponse }
        progress.usage = AskTokenUsage.parse(body, style: style, previous: progress.usage)
        switch style {
        case .responses: break
        case .openAI:
            guard let choice = (body["choices"] as? [[String: Any]])?.first else { return }
            if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
                finished = true
                progress.truncated = finish == "length"
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            progress.text += delta["content"] as? String ?? ""
            progress.reasoning += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = part["index"] as? Int else { throw invalid() }
                var call = try tool(index)
                let id = part["id"] as? String ?? ""
                let repeatedID = !id.isEmpty && id == call.id
                if let id = part["id"] as? String {
                    call.id = id
                }
                if let context = part["provider_context"] as? String {
                    guard context.utf8.count <= 256000 else { throw invalid() }
                    call.providerContext = context
                }
                let function = part["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                // Some providers repeat the full name and ID on every argument delta.
                if !repeatedID || name != call.function.name {
                    call.function.name += name
                }
                let arguments = function["arguments"] as? String ?? ""
                if call.function.arguments.isEmpty,
                   arguments.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
                    emptyArgumentPrefixes[index] = arguments.count
                }
                call.function.arguments += arguments
                calls[index] = call
            }
        case .anthropic:
            let type = body["type"] as? String ?? ""
            if type == "error" {
                throw invalid()
            }
            if type == "message_stop" {
                finished = true
            }
            if type == "message_delta", let delta = body["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                progress.truncated = reason == "max_tokens"
            }
            if type == "content_block_start", let block = body["content_block"] as? [String: Any] {
                guard let index = body["index"] as? Int, (0..<64).contains(index) else { throw invalid() }
                nativeBlocks[index] = block
                if block["type"] as? String == "tool_use" {
                    guard let index = body["index"] as? Int else { throw invalid() }
                    var call = try tool(index)
                    call.id = block["id"] as? String ?? call.id
                    call.function.name = block["name"] as? String ?? ""
                    if let input = block["input"] as? [String: Any], !input.isEmpty {
                        call.function.arguments = try String(
                            decoding: JSONSerialization.data(withJSONObject: input),
                            as: UTF8.self
                        )
                    }
                    calls[index] = call
                }
                progress.text += block["text"] as? String ?? ""
                progress.reasoning += block["thinking"] as? String ?? ""
            }
            if type == "content_block_stop", let index = body["index"] as? Int, var call = calls[index],
               call.function.arguments.isEmpty {
                call.function.arguments = "{}"; calls[index] = call
            }
            if type == "content_block_delta", let delta = body["delta"] as? [String: Any] {
                if let index = body["index"] as? Int, var block = nativeBlocks[index] {
                    for field in ["text", "thinking", "signature"] {
                        if let value = delta[field] as? String {
                            let joined = (block[field] as? String ?? "") + value
                            guard joined.utf8.count <= 256000 else { throw invalid() }
                            block[field] = joined
                        }
                    }
                    nativeBlocks[index] = block
                }
                progress.text += delta["text"] as? String ?? ""
                progress.reasoning += delta["thinking"] as? String ?? ""
                if let fragment = delta["partial_json"] as? String, let index = body["index"] as? Int {
                    var call = try tool(index); call.function.arguments += fragment; calls[index] = call
                }
            }
        case .gemini:
            guard let candidate = (body["candidates"] as? [[String: Any]])?.first else { return }
            if let finish = candidate["finishReason"] as? String, !finish.isEmpty {
                finished = true
                progress.truncated = finish == "MAX_TOKENS"
            }
            let content = candidate["content"] as? [String: Any] ?? [:]
            for part in content["parts"] as? [[String: Any]] ?? [] {
                if let text = part["text"] as? String {
                    if part["thought"] as? Bool == true {
                        progress.reasoning += text
                    } else {
                        progress.text += text
                    }
                }
                if let function = part["functionCall"] as? [String: Any] {
                    let index = calls.count
                    var call = try tool(index)
                    call.id = function["id"] as? String ?? UUID().uuidString
                    call.function.name = function["name"] as? String ?? ""
                    call.function.arguments = try String(
                        decoding: JSONSerialization.data(withJSONObject: function["args"] ?? [:]),
                        as: UTF8.self
                    )
                    call.thoughtSignature = part["thoughtSignature"] as? String
                    calls[index] = call
                }
            }
        }
        if style == .anthropic, finished, let first = calls.keys.sorted().first {
            for (index, call) in calls {
                nativeBlocks[index]?["input"] = try JSONSerialization.jsonObject(
                    with: Data(call.function.arguments.utf8)
                )
            }
            calls[first]?.providerContext = try ProviderContinuation.encode(
                nativeBlocks.keys.sorted().compactMap { nativeBlocks[$0] }, protocolName: "anthropic"
            )
        }
        progress.toolCalls = calls.keys.sorted().compactMap { calls[$0] }
        guard progress.text.utf8.count <= 256_000, progress.reasoning.utf8.count <= 256_000,
              progress.toolCalls.allSatisfy({ $0.function.arguments.utf8.count <= 64000 }) else { throw invalid() }
    }

    func result() throws -> (String, [AskToolCall]) {
        if style == .responses { return try responses.result() }
        guard finished, !progress.text.isEmpty || !progress.toolCalls.isEmpty else { throw invalid() }
        var resultCalls: [AskToolCall] = []
        for index in calls.keys.sorted() {
            guard var call = calls[index] else { continue }
            if let prefix = emptyArgumentPrefixes[index] {
                // Only replace a standalone initial placeholder with a complete object.
                // Leave malformed suffixes intact so the validation below rejects them.
                let candidate = String(call.function.arguments.dropFirst(prefix))
                if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any] {
                    call.function.arguments = candidate
                }
            }
            guard !call.id.hasPrefix("pending-"), !call.function.name.isEmpty,
                  let data = call.function.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw invalid() }
            resultCalls.append(call)
        }
        return (progress.text, resultCalls)
    }

    private func tool(_ index: Int) throws -> AskToolCall {
        guard (0 ..< 64).contains(index), calls[index] != nil || calls.count < 8 else { throw invalid() }
        return calls[index] ?? .init(id: "pending-\(index)", type: "function", function: .init(name: "", arguments: ""))
    }

    private func invalid() -> AskStreamError {
        .invalidResponse
    }
}

extension AskCustomInference {
    func stream(_ request: URLRequest, style: AskProviderStream.Style,
                onUsage: (@Sendable (AskTokenUsage) async -> Void)? = nil,
                onProgress: @Sendable (AskStreamProgress) async -> Void) async throws -> (String, [AskToolCall]) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AskReasoningRequest.isRejection(status: status) ? AskStreamError.rejected : AskStreamError.requestFailed
        }
        var frame = AskSSEFrame()
        var parser = AskProviderStream(style: style)
        let started = ContinuousClock.now
        var last = started - .seconds(1)
        var reasoningMilliseconds = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            if let (_, data) = try frame.push(byte) {
                try parser.consume(data)
                if let usage = parser.progress.usage { await onUsage?(usage) }
                let now = ContinuousClock.now
                if !parser.progress.reasoning.isEmpty && parser.progress.text.isEmpty {
                    let elapsed = started.duration(to: now).components
                    reasoningMilliseconds = min(
                        180_000,
                        Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
                    )
                }
                if now - last >= .milliseconds(80) || parser.finished {
                    var progress = parser.progress; progress.reasoningMilliseconds = reasoningMilliseconds
                    await onProgress(progress); last = now
                }
                if data == "[DONE]" || ((style == .anthropic || style == .responses) && parser.finished) {
                    break
                }
            }
        }
        var progress = parser.progress; progress.reasoningMilliseconds = reasoningMilliseconds
        await onProgress(progress)
        return try parser.result()
    }
}
