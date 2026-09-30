import Foundation

struct AskToolDefinition: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
}

struct AskToolCall: Codable, Identifiable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        var name: String
        var arguments: String
    }
    var id: String
    var type: String?
    var function: Function
    var thoughtSignature: String?
}

struct AskMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var role: String
    var text: String
    var selection: String?
    var source: String?
    var image: String?
    var toolCalls: [AskToolCall]?
    var toolCallId: String?
    var isError: Bool?
    var createdAt: Date
    var reasoning: String? = nil
    var reasoningMilliseconds: Int? = nil
    var reasoningEffort: String? = nil
    var references: [AskReference]? = nil
    var runId: String? = nil
}

struct AskRun: Codable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var status: String
    var error: String?
    var steps: Int
    var updatedAt: Date
    var tools: [AskToolDefinition]
    var pending: [AskToolCall]
    var assistantId: String? = nil
    var reasoning: String? = nil
    var reasoningMilliseconds: Int? = nil
    var previewTools: [AskToolCall]? = nil
    var preview: String? = nil
    var modelRef: String? = nil
    var inference: AskInference? = nil

    var reasoningEffort: String? = nil

    var isActive: Bool { status == "running" || status == "waiting_tool" || status == "waiting_inference" }
}

struct AskConversation: Codable, Identifiable, Equatable, Sendable {
    @AskConversationID var id: String
    var title: String
    var revision: Int64
    var updatedAt: Date
    var messages: [AskMessage]
    var run: AskRun?
    var summary: String?
    var summaryThrough: Int?
    var modelRef: String? = nil
    var usage: AskConversationUsage? = nil
    var contextUsage: AskContextUsage? = nil
}

struct AskConversationSummary: Codable, Identifiable, Equatable, Sendable {
    @AskConversationID var id: String
    var title: String
    var updatedAt: Date
}

struct AskSendRequest: Codable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var text: String
    var selection: String?
    var source: String?
    var image: String?
    var tools: [AskToolDefinition]
    var modelRef: String? = nil
    var reasoningEffort: String? = nil
    var references: [AskReference]? = nil
}

/// Replaces the latest assistant reply with a fresh run on the same question.
/// The model and tools are optional: the server falls back to the conversation's
/// current model and the previous run's toolset.
struct AskRegenerateRequest: Codable, Equatable, Sendable {
    var messageId: String
    var deviceId: String
    var modelRef: String? = nil
    var tools: [AskToolDefinition]? = nil
}

struct AskToolResultRequest: Codable, Equatable, Sendable {
    var runId: String
    var deviceId: String
    var toolCallId: String
    var content: String
    var isError: Bool
    var image: String? = nil
}

struct AskDraft: Codable, Equatable, Sendable {
    var text = ""
    var includeScreenshot = true
    var screenshot: String?
    var selection: String?
    var source: String?
    var capturedAt: Date?
    var modelRef: String? = nil

    var references: [AskReference]? = nil

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (references ?? []).contains { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var referencesWithinLimit: Bool {
        let items = references ?? []
        return items.count <= 32 && items.reduce(0) { $0 + $1.text.utf8.count + $1.question.utf8.count } <= 64000
    }

    func request(deviceId: String, tools: [AskToolDefinition], id: String = UUID().uuidString) -> AskSendRequest {
        AskSendRequest(
            id: id, deviceId: deviceId, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            selection: selection, source: source,
            image: includeScreenshot ? screenshot : nil, tools: tools, modelRef: modelRef, references: references
        )
    }

    static var followUp: AskDraft { AskDraft(includeScreenshot: false) }
}

enum AskCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
        }
        return decoder
    }
}

/// PostgreSQL UUID columns return lowercase, while legacy JSON snapshots retain
/// the client's uppercase spelling. Identity must be identical at both boundaries.
@propertyWrapper
struct AskConversationID: Codable, Equatable, Sendable {
    private var value: String
    var wrappedValue: String {
        get { value }
        set { value = Self.canonical(newValue) }
    }
    init(wrappedValue: String) { value = Self.canonical(wrappedValue) }
    init(from decoder: Decoder) throws {
        value = Self.canonical(try decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    static func canonical(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString.lowercased() ?? id
    }
    static func legacy(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString ?? id
    }
}
