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
        case let .string(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .bool(value):
            value
        case let .array(values):
            values.map(\.foundationValue)
        case let .object(values):
            values.mapValues(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

protocol LLMService {
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error>
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String
    /// `complete`, delivered as it is generated: each element is the next piece of text.
    func streamComplete(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error>
}

extension LLMService {
    /// Services that cannot stream deliver the whole completion as one piece.
    func streamComplete(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
                    if !text.isEmpty { continuation.yield(text) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
