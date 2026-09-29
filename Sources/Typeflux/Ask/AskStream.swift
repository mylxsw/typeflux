import Foundation

enum AskStreamError: Error { case invalidResponse, requestFailed }

struct AskStreamProgress: Equatable, Sendable {
    var text = ""
    var reasoning = ""
    var toolCalls: [AskToolCall] = []
    var reasoningMilliseconds = 0
}

/// One bounded SSE decoder shared by provider and conversation streams.
struct AskSSEFrame {
    var limit = 2_000_000
    var event = "message"
    var data = ""
    private var lineBytes = Data()
    /// AsyncBytes.lines omits empty lines, which are SSE frame delimiters.
    /// Decode bytes directly to preserve those boundaries and split UTF-8 safely.
    mutating func push(_ byte: UInt8) throws -> (String, String)? {
        if byte == 10 {
            if lineBytes.last == 13 {
                lineBytes.removeLast()
            }
            guard let line = String(data: lineBytes, encoding: .utf8) else { throw AskStreamError.invalidResponse }
            lineBytes.removeAll(keepingCapacity: true)
            return try append(line)
        }
        guard lineBytes.count < limit else { throw AskStreamError.invalidResponse }
        lineBytes.append(byte)
        return nil
    }

    mutating func append(_ line: String) throws -> (String, String)? {
        if line.isEmpty {
            defer { event = "message"; data = "" }
            return data.isEmpty ? nil : (event, String(data.dropLast()))
        }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " {
                value = value.dropFirst()
            }
            data += value + "\n"
            guard data.utf8.count <= limit else { throw AskStreamError.invalidResponse }
        }
        return nil
    }
}

struct AskProviderStream {
    enum Style { case openAI, anthropic, gemini }
    var style: Style
    private(set) var progress = AskStreamProgress()
    private(set) var finished = false
    private var calls: [Int: AskToolCall] = [:]

    mutating func consume(_ data: String) throws {
        if data == "[DONE]" {
            finished = true; return
        }
        guard let body = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              body["error"] == nil else { throw AskStreamError.invalidResponse }
        switch style {
        case .openAI:
            guard let choice = (body["choices"] as? [[String: Any]])?.first else { return }
            if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
                finished = true
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            progress.text += delta["content"] as? String ?? ""
            progress.reasoning += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = part["index"] as? Int else { throw invalid() }
                var call = try tool(index)
                if let id = part["id"] as? String {
                    call.id = id
                }
                let function = part["function"] as? [String: Any] ?? [:]
                call.function.name += function["name"] as? String ?? ""
                call.function.arguments += function["arguments"] as? String ?? ""
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
            if type == "content_block_start", let block = body["content_block"] as? [String: Any] {
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
        progress.toolCalls = calls.keys.sorted().compactMap { calls[$0] }
        guard progress.text.utf8.count <= 256_000, progress.reasoning.utf8.count <= 256_000,
              progress.toolCalls.allSatisfy({ $0.function.arguments.utf8.count <= 64000 }) else { throw invalid() }
    }

    func result() throws -> (String, [AskToolCall]) {
        guard finished, !progress.text.isEmpty || !progress.toolCalls.isEmpty else { throw invalid() }
        for call in progress.toolCalls {
            guard !call.id.hasPrefix("pending-"), !call.function.name.isEmpty,
                  let data = call.function.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw invalid() }
        }
        return (progress.text, progress.toolCalls)
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
                onProgress: @Sendable (AskStreamProgress) async -> Void) async throws -> (String, [AskToolCall]) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw AskStreamError.requestFailed
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
                if data == "[DONE]" || (style == .anthropic && parser.finished) {
                    break
                }
            }
        }
        var progress = parser.progress; progress.reasoningMilliseconds = reasoningMilliseconds
        await onProgress(progress)
        return try parser.result()
    }
}
