import Foundation

struct ResponsesStream {
    private(set) var progress = AskStreamProgress()
    private(set) var finished = false
    private var calls: [Int: AskToolCall] = [:]

    mutating func consume(_ data: String) throws {
        guard !finished, let body = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let type = body["type"] as? String else { throw AskStreamError.invalidResponse }
        switch type {
        case "error", "response.failed": throw AskStreamError.requestFailed
        case "response.output_text.delta": progress.text += body["delta"] as? String ?? ""
        case "response.reasoning_summary_text.delta": progress.reasoning += body["delta"] as? String ?? ""
        case "response.output_item.added":
            try addCall(body)
        case "response.function_call_arguments.delta":
            guard let index = body["output_index"] as? Int,
                  calls[index] != nil else { throw AskStreamError.invalidResponse }
            calls[index]?.function.arguments += body["delta"] as? String ?? ""
        case "response.completed", "response.incomplete":
            try finish(body, truncated: type == "response.incomplete")
        default: break
        }
        if !finished {
            progress.toolCalls = calls.keys.sorted().compactMap { calls[$0] }
        }
        try validateProgress()
    }

    private func validateProgress() throws {
        guard progress.text.utf8.count <= 256_000, progress.reasoning.utf8.count <= 256_000,
              progress.toolCalls.count <= 8,
              progress.toolCalls.allSatisfy({ $0.function.arguments.utf8.count <= 64000 })
        else { throw AskStreamError.invalidResponse }
    }

    private mutating func finish(_ body: [String: Any], truncated: Bool) throws {
        guard let response = body["response"] as? [String: Any],
              response["status"] as? String == (truncated ? "incomplete" : "completed") else {
            throw AskStreamError.invalidResponse
        }
        let result = try ResponsesAPI.reply(response, allowIncomplete: true)
        progress.text = result.0
        progress.toolCalls = result.1
        progress.usage = AskTokenUsage.parse(response, style: .responses)
        progress.truncated = truncated
        finished = true
    }

    private mutating func addCall(_ body: [String: Any]) throws {
        if let item = body["item"] as? [String: Any], item["type"] as? String == "function_call" {
            guard let index = body["output_index"] as? Int, index >= 0,
                  let id = item["call_id"] as? String,
                  let name = item["name"] as? String else { throw AskStreamError.invalidResponse }
            calls[index] = .init(
                id: id,
                type: "function",
                function: .init(name: name, arguments: item["arguments"] as? String ?? "")
            )
        }
    }

    func result() throws -> (String, [AskToolCall]) {
        guard finished else { throw AskStreamError.invalidResponse }
        return (progress.text, progress.toolCalls)
    }
}
