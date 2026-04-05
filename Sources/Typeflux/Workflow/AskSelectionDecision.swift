import Foundation

struct AskSelectionDecision: Codable, Equatable, Sendable {
    enum AnswerEdit: String, Codable, Equatable, Sendable {
        case answer
        case edit
    }

    let answerEdit: AnswerEdit
    let content: String

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let schema = LLMJSONSchema(
        name: "answer_or_edit_selection",
        schema: [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("answer_edit"), .string("content")]),
            "properties": .object([
                "answer_edit": .object([
                    "type": .string("string"),
                    "enum": .array([.string("answer"), .string("edit")])
                ]),
                "content": .object([
                    "type": .string("string")
                ])
            ])
        ]
    )

    static let tool = LLMAgentTool(
        name: "answer_or_edit_selection",
        description: """
        Decide whether the user wants a read-only answer about the selected text or wants the selected text rewritten in place.
        Return answer_edit=\"answer\" with the final answer in content, or answer_edit=\"edit\" with the final rewritten text in content.
        """,
        inputSchema: schema
    )

    var isValid: Bool {
        !trimmedContent.isEmpty
    }

    init(answerEdit: AnswerEdit, content: String) {
        self.answerEdit = answerEdit
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let answerEdit = try container.decodeIfPresent(AnswerEdit.self, forKey: .answerEdit) {
            self.answerEdit = answerEdit
            self.content = try container.decode(String.self, forKey: .content)
            return
        }

        // Backward-compatible decoding for older provider outputs using action/response.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.answerEdit = try legacy.decode(AnswerEdit.self, forKey: .action)
        self.content = try legacy.decode(String.self, forKey: .response)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(answerEdit, forKey: .answerEdit)
        try container.encode(content, forKey: .content)
    }

    private enum CodingKeys: String, CodingKey {
        case answerEdit = "answer_edit"
        case content
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case action
        case response
    }
}
