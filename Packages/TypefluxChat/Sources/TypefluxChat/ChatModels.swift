import Foundation

/// Mobile projection of the cloud document. Unknown desktop-only metadata is
/// ignored during decoding; mobile never PUTs this projection over the document.
public struct ChatConversation: Decodable, Equatable, Identifiable, Sendable {
    @ChatConversationID public var id: String
    public var title: String
    public var revision: Int64
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var run: ChatRun?

    public init(id: String, title: String, revision: Int64 = 0, updatedAt: Date = Date(),
                messages: [ChatMessage] = [], run: ChatRun? = nil) {
        self.id = id; self.title = title; self.revision = revision
        self.updatedAt = updatedAt; self.messages = messages; self.run = run
    }
}

public struct ChatConversationSummary: Codable, Equatable, Identifiable, Sendable {
    @ChatConversationID public var id: String
    public var title: String
    public var updatedAt: Date
    public init(id: String, title: String, updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
    }
}

public struct ChatMessage: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var createdAt: Date
    public var image: String?
    public var reasoning: String?
    public var toolCalls: [ChatToolCall]?
    public var toolCallId: String?
    public var isError: Bool?

    public init(id: String, role: String, text: String, createdAt: Date = Date(), image: String? = nil,
                reasoning: String? = nil, toolCalls: [ChatToolCall]? = nil, toolCallId: String? = nil,
                isError: Bool? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
        self.image = image; self.reasoning = reasoning; self.toolCalls = toolCalls
        self.toolCallId = toolCallId; self.isError = isError
    }
}

public struct ChatToolCall: Codable, Equatable, Identifiable, Sendable {
    public struct Function: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: String
        public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
    }
    public var id: String
    public var type: String?
    public var function: Function
    public var thoughtSignature: String?
    public init(id: String, type: String? = nil, function: Function, thoughtSignature: String? = nil) {
        self.id = id; self.type = type; self.function = function; self.thoughtSignature = thoughtSignature
    }
}

public struct ChatRun: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceId: String
    public var status: String
    public var updatedAt: Date
    public var preview: String?
    public var reasoning: String?
    public var error: String?
    public var pending: [ChatToolCall]
    private enum CodingKeys: String, CodingKey {
        case id, deviceId, status, updatedAt, preview, reasoning, error, pending
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        status = try values.decode(String.self, forKey: .status)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        preview = try values.decodeIfPresent(String.self, forKey: .preview)
        reasoning = try values.decodeIfPresent(String.self, forKey: .reasoning)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        pending = try values.decodeIfPresent([ChatToolCall].self, forKey: .pending) ?? []
    }
    public var isActive: Bool { !["completed", "failed", "cancelled"].contains(status) }
    /// These runs require a desktop executor. Mobile can display or cancel them,
    /// but must never try to fulfill their tool/inference requests.
    public var requiresDesktop: Bool { ["waiting_tool", "waiting_inference"].contains(status) }
    public init(id: String, deviceId: String, status: String, updatedAt: Date = Date(),
                preview: String? = nil, reasoning: String? = nil, error: String? = nil,
                pending: [ChatToolCall] = []) {
        self.id = id; self.deviceId = deviceId; self.status = status; self.updatedAt = updatedAt
        self.preview = preview; self.reasoning = reasoning; self.error = error; self.pending = pending
    }
}

public struct ChatModel: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var vision: Bool?
    /// Catalog pricing uses decimal strings to avoid rounding billing metadata.
    /// Older servers omit pricing entirely.
    public var pricing: [String: String]?
    public var reference: String { "cloud:" + id }
    public init(id: String, name: String, vision: Bool? = nil, pricing: [String: String]? = nil) {
        self.id = id; self.name = name; self.vision = vision; self.pricing = pricing
    }
}

/// An explicitly cloud-only turn: it cannot advertise or inherit desktop tools.
public struct ChatSendRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var deviceId: String
    public var text: String
    public var image: String?
    public var modelRef: String?
    public let tools: [String] = []
    public let platform = "iOS"
    public var timeZone: String
    public var locale: String
    public init(id: String = UUID().uuidString, deviceId: String, text: String,
                image: String? = nil, modelRef: String? = nil,
                timeZone: String = TimeZone.current.identifier, locale: String = Locale.current.identifier) {
        self.id = id; self.deviceId = deviceId; self.text = text
        self.image = image; self.modelRef = modelRef; self.timeZone = timeZone; self.locale = locale
    }
}
