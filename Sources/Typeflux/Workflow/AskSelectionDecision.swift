import Foundation

struct AskSelectionDecision: Codable, Equatable, Sendable {
    enum Action: String, Codable, Equatable, Sendable {
        case answer
        case edit
    }

    let action: Action
    let response: String

    var trimmedResponse: String {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let schema = LLMJSONSchema(
        name: "answer_or_edit_selection",
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

    static let tool = LLMAgentTool(
        name: "answer_or_edit_selection",
        description: """
        Decide whether the user wants a read-only answer about the selected text or wants the selected text rewritten in place.
        Return action=\"answer\" with the final answer in response, or action=\"edit\" with response=\"\".
        """,
        inputSchema: schema
    )

    var isValid: Bool {
        switch action {
        case .answer:
            return !trimmedResponse.isEmpty
        case .edit:
            return response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
