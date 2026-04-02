import Foundation

struct AskSelectionDecision: Equatable {
    enum Action: String, Equatable {
        case answer
        case edit
    }

    let action: Action
    let response: String

    var trimmedResponse: String {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let schema = LLMJSONSchema(
        name: "ask_selection_decision",
        schema: [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("action"), .string("response")]),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("answer"), .string("edit")])
                ]),
                "response": .object([
                    "type": .string("string")
                ])
            ])
        ]
    )

    static func parse(from response: String) -> AskSelectionDecision? {
        let normalized = normalizedJSONString(from: response)

        guard let data = normalized.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionRaw = (json["action"] as? String) ?? (json["decision"] as? String),
              let action = Action(rawValue: actionRaw),
              let answer = json["response"] as? String else {
            return nil
        }

        return AskSelectionDecision(action: action, response: answer)
    }

    static func parseOrDefaultToAnswer(from response: String) -> AskSelectionDecision? {
        if let parsed = parse(from: response) {
            return parsed
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AskSelectionDecision(action: .answer, response: trimmed)
    }

    private static func normalizedJSONString(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            if lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                let body = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if body.hasPrefix("{"), body.hasSuffix("}") {
                    if body.lowercased().hasPrefix("json\n") {
                        return String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return body
                }
            }
        }

        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end {
            return String(trimmed[start...end])
        }

        return trimmed
    }
}
