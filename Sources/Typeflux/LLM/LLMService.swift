import Foundation

struct LLMJSONSchema: Sendable {
    let name: String
    let schema: [String: AnySendable]
    let strict: Bool

    init(name: String, schema: [String: AnySendable], strict: Bool = true) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }

    var jsonObject: [String: Any] {
        schema.mapValues(\.foundationValue)
    }
}

enum AnySendable: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnySendable])
    case object([String: AnySendable])
    case null

    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        case .null:
            return NSNull()
        }
    }
}

protocol LLMService {
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error>
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String
}
