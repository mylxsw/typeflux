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
    /// Sent into a run that was already working ("jumped the queue").
    var steered: Bool? = nil
    var attachments: [AskAttachment]? = nil
    /// Skills and MCP servers the user chose for this question with a slash command.
    var skills: [AskSkillUse]? = nil
    var mcpServers: [String]? = nil
    var harness: AskHarnessContract? = nil
    var diagnostic: AskResultDiagnostic? = nil

    /// The screenshot or an attached image; such a conversation needs a vision model.
    var hasImage: Bool { image != nil || attachments?.contains { $0.kind == .image } == true }
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
    /// The model's latest update_plan list.
    var plan: [AskPlanItem]? = nil
    /// Extra steps granted after messages were sent into the running run.
    var extraSteps: Int? = nil

    var isActive: Bool { status == "running" || status == "waiting_tool" || status == "waiting_inference" }
}

struct AskPlanItem: Codable, Equatable, Sendable, Hashable {
    var step: String
    var status: String
}

struct AskConversation: Codable, Identifiable, Equatable, Sendable {
    /// Optional, inert contract metadata. Legacy snapshots have no envelope.
    var harness: AskHarnessContract? = nil
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
    /// Memory pinned by the server when the conversation started.
    var memory: AskMemory? = nil
    /// The latest question asked without the pinned memory; the snapshot stays.
    var memoryOff: Bool?
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
    var attachments: [AskAttachment]? = nil
    var skills: [AskSkillUse]? = nil
    var mcpServers: [String]? = nil
    var memory: AskMemory? = nil
    /// A follow-up asked without the conversation's pinned memory; omitted otherwise.
    var memoryOff: Bool?
    /// Device context for the server's environment prompt (IANA zone, BCP 47 locale).
    var timeZone: String? = TimeZone.current.identifier
    var locale: String? = Locale.current.identifier(.bcp47)
}

/// A skill the user chose for one question, with the instructions it carries,
/// so the model follows it without first having to load it.
struct AskSkillUse: Codable, Equatable, Sendable {
    var name: String
    var instructions: String
}

extension AskSendRequest {
    var sendsImage: Bool { image != nil || attachments?.contains { $0.kind == .image } == true }
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

/// Hands a message to the active run; the model reads it at its next step boundary.
struct AskSteerRequest: Codable, Equatable, Sendable {
    var runId: String
    var deviceId: String
    var id: String
    var text: String
    var selection: String?
    var source: String?
    var image: String?
    var references: [AskReference]? = nil
    var attachments: [AskAttachment]? = nil
    var skills: [AskSkillUse]? = nil
    var mcpServers: [String]? = nil

    init(runId: String, message: AskSendRequest) {
        self.runId = runId; deviceId = message.deviceId; id = message.id; text = message.text
        selection = message.selection; source = message.source; image = message.image; references = message.references
        attachments = message.attachments; skills = message.skills; mcpServers = message.mcpServers
    }
}

struct AskToolResultRequest: Codable, Equatable, Sendable {
    var runId: String
    var deviceId: String
    var toolCallId: String
    var content: String
    var isError: Bool
    var image: String? = nil
    /// Raw result metadata, independent of the conservative legacy projection.
    var harness: AskHarnessContract? = nil
}

struct AskDraft: Codable, Equatable, Sendable {
    var text = ""
    var includeScreenshot = true
    var screenshot: String?
    var selection: String?
    var source: String?
    /// Bundle identifier of `source`'s app; nil for drafts saved before it existed.
    var sourceBundleID: String? = nil
    var capturedAt: Date?
    var modelRef: String? = nil

    var references: [AskReference]? = nil
    /// `nil` means memory has not been resolved for this draft; an empty value
    /// means it is unavailable or the user removed it.
    var memory: AskMemory? = nil
    /// The user switched memory off for this question. The captured memory is
    /// kept so the chip can switch it back on; nil in drafts saved before this.
    /// In a follow-up nil inherits the conversation's latest choice, and false
    /// switches pinned memory back on.
    var memoryOff: Bool? = nil
    /// The user switched the selected text off for this question. Like memory it
    /// is kept, so the chip can switch it back on; nil in drafts saved before this.
    var selectionOff: Bool? = nil
    /// Files, images and folders the user added; nil when there are none.
    var attachments: [AskAttachment]? = nil
    /// Skill and MCP server names chosen with a slash command for the next message.
    var skills: [String]? = nil
    var mcpServers: [String]? = nil
    /// Where a new conversation is kept: true on this Mac, false in Typeflux Cloud,
    /// nil for the default from settings. Ignored once the conversation exists.
    var storesLocally: Bool? = nil

    /// The selection that rides with the question: nil once switched off.
    var sentSelection: String? { selectionOff == true ? nil : selection }

    /// Attachments alone are a question too: "what is in this file" is implied.
    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (references ?? []).contains { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
            !(attachments ?? []).isEmpty
    }

    /// A conversation opened with attachments only is named after the first one.
    var title: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? attachments?.first?.name ?? typed : typed
    }

    /// A screenshot or an attached image rides with the question.
    var sendsImage: Bool { (includeScreenshot && screenshot != nil) || attachedImageCount > 0 }

    var referencesWithinLimit: Bool {
        let items = references ?? []
        return items.count <= 32 && items.reduce(0) { $0 + $1.text.utf8.count + $1.question.utf8.count } <= 64000
    }

    func request(deviceId: String, tools: [AskToolDefinition], id: String = UUID().uuidString) -> AskSendRequest {
        AskSendRequest(
            id: id, deviceId: deviceId, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            selection: sentSelection, source: source,
            image: includeScreenshot ? screenshot : nil, tools: tools, modelRef: modelRef, references: references,
            attachments: attachments, mcpServers: mcpServers
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
