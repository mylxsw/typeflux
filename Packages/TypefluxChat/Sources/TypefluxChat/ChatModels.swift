import Foundation

/// Mobile projection of the cloud document. Unknown desktop-only metadata is
/// ignored during decoding; mobile never PUTs this projection over the document.
public struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    @ChatConversationID public var id: String
    public var title: String
    public var revision: Int64
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var run: ChatRun?
    /// `auto` once a title was generated, `manual` after a rename; nil while the
    /// conversation still carries its provisional title.
    public var titleSource: String?

    public init(id: String, title: String, revision: Int64 = 0, updatedAt: Date = Date(),
                messages: [ChatMessage] = [], run: ChatRun? = nil, titleSource: String? = nil) {
        self.id = id; self.title = title; self.revision = revision
        self.updatedAt = updatedAt; self.messages = messages; self.run = run; self.titleSource = titleSource
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

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var createdAt: Date
    public var image: String?
    public var reasoning: String?
    public var reasoningMilliseconds: Int?
    public var attachments: [ChatAttachment]?
    public var toolCalls: [ChatToolCall]?
    public var toolCallId: String?
    public var isError: Bool?
    /// The model that wrote this answer, for answers written on this device.
    public var modelRef: String?
    /// The public Typeflux Cloud model that wrote this answer, including when
    /// the request asked for the default. Older servers omit both.
    public var modelAlias: String?
    public var modelName: String?

    public init(id: String, role: String, text: String, createdAt: Date = Date(), image: String? = nil,
                reasoning: String? = nil, reasoningMilliseconds: Int? = nil, attachments: [ChatAttachment]? = nil,
                toolCalls: [ChatToolCall]? = nil, toolCallId: String? = nil,
                isError: Bool? = nil, modelRef: String? = nil, modelAlias: String? = nil, modelName: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
        self.image = image; self.reasoning = reasoning; self.toolCalls = toolCalls
        self.reasoningMilliseconds = reasoningMilliseconds; self.attachments = attachments
        self.toolCallId = toolCallId; self.isError = isError; self.modelRef = modelRef
        self.modelAlias = modelAlias; self.modelName = modelName
    }

    public var hasImage: Bool { image != nil || attachments?.contains { $0.kind == "image" } == true }

    /// Inline images from both legacy screenshots and newer desktop attachments.
    /// The presentation layer validates the data URL before decoding it.
    public var imageDataURLs: [String] {
        (image.map { [$0] } ?? []) + (attachments ?? []).compactMap { $0.kind == "image" ? $0.image : nil }
    }
}

/// Read-only attachment projection. Desktop file contents and local folder paths
/// are deliberately not exposed; inline images can be displayed on any device.
public struct ChatAttachment: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String?
    public var name: String?
    public var image: String?
    public init(kind: String, id: String? = nil, name: String? = nil, image: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.image = image
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
    public var providerContext: String?
    public var thoughtSignature: String?
    public init(id: String, type: String? = nil, function: Function, thoughtSignature: String? = nil, providerContext: String? = nil) {
        self.id = id; self.type = type; self.function = function; self.thoughtSignature = thoughtSignature; self.providerContext = providerContext
    }
}

public struct ChatRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceId: String
    public var status: String
    public var updatedAt: Date
    public var preview: String?
    public var reasoning: String?
    public var reasoningMilliseconds: Int?
    public var error: String?
    public var pending: [ChatToolCall]
    /// The model reference the run was started with, e.g. `cloud:default`.
    public var modelRef: String?
    /// The public catalog model serving the run; `cloud:default` resolves to it.
    public var modelAlias: String?
    public var modelName: String?
    private enum CodingKeys: String, CodingKey {
        case id, deviceId, status, updatedAt, preview, reasoning, reasoningMilliseconds, error, pending, modelRef
        case modelAlias, modelName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        status = try values.decode(String.self, forKey: .status)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        preview = try values.decodeIfPresent(String.self, forKey: .preview)
        reasoning = try values.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningMilliseconds = try values.decodeIfPresent(Int.self, forKey: .reasoningMilliseconds)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        pending = try values.decodeIfPresent([ChatToolCall].self, forKey: .pending) ?? []
        modelRef = try values.decodeIfPresent(String.self, forKey: .modelRef)
        modelAlias = try values.decodeIfPresent(String.self, forKey: .modelAlias)
        modelName = try values.decodeIfPresent(String.self, forKey: .modelName)
    }
    public var isActive: Bool { !["completed", "failed", "cancelled"].contains(status) }
    /// These runs require a desktop executor. Mobile can display or cancel them,
    /// but must never try to fulfill their tool/inference requests.
    public var requiresDesktop: Bool { ["waiting_tool", "waiting_inference"].contains(status) }
    /// The server stopped at a checkpoint because the account ran out of credits.
    /// It continues only after an explicit resume; nothing streams meanwhile.
    public var isPausedForCredits: Bool { status == "paused_credits" }
    public init(id: String, deviceId: String, status: String, updatedAt: Date = Date(),
                preview: String? = nil, reasoning: String? = nil, reasoningMilliseconds: Int? = nil, error: String? = nil,
                pending: [ChatToolCall] = [], modelRef: String? = nil, modelAlias: String? = nil,
                modelName: String? = nil) {
        self.id = id; self.deviceId = deviceId; self.status = status; self.updatedAt = updatedAt
        self.preview = preview; self.reasoning = reasoning; self.error = error; self.pending = pending
        self.reasoningMilliseconds = reasoningMilliseconds; self.modelRef = modelRef
        self.modelAlias = modelAlias; self.modelName = modelName
    }
}

public struct ChatModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var vision: Bool?
    public var reasoning: Bool?
    public var reasoningEfforts: [String]?
    public var contextWindowTokens: Int?
    public var maxOutputTokens: Int?
    /// Catalog pricing uses decimal strings to avoid rounding billing metadata.
    /// Older servers omit pricing entirely.
    public var pricing: [String: String]?
    /// A model from the user's own provider, answered on this device. Nil for Typeflux Cloud.
    public var providerName: String?
    private var localReference: String?
    /// `cloud:<alias>` for Typeflux Cloud; `local:<provider>/<model>` for the user's own models.
    public var reference: String { localReference ?? "cloud:" + id }
    public var isLocal: Bool { localReference != nil }
    public init(id: String, name: String, vision: Bool? = nil, pricing: [String: String]? = nil,
                reasoning: Bool? = nil, reasoningEfforts: [String]? = nil,
                contextWindowTokens: Int? = nil, maxOutputTokens: Int? = nil) {
        self.id = id; self.name = name; self.vision = vision; self.pricing = pricing
        self.reasoning = reasoning; self.reasoningEfforts = reasoningEfforts
        self.contextWindowTokens = contextWindowTokens; self.maxOutputTokens = maxOutputTokens
    }

    /// A model of the user's own provider. Its reference never starts with `cloud:`,
    /// so it can never be sent to Typeflux as a Cloud selection.
    public static func local(reference: String, id: String, name: String, providerName: String,
                             vision: Bool) -> ChatModel {
        var model = ChatModel(id: id, name: name, vision: vision)
        model.localReference = reference
        model.providerName = providerName
        return model
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, vision, pricing, capabilities, reasoningEfforts, contextWindowTokens, maxOutputTokens
    }

    private struct Capabilities: Codable {
        var reasoning: Bool?
    }

    /// Encodes the Cloud catalog shape so a cached catalog decodes like a fresh one.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(vision, forKey: .vision)
        try values.encodeIfPresent(pricing, forKey: .pricing)
        if let reasoning {
            try values.encode(Capabilities(reasoning: reasoning), forKey: .capabilities)
        }
        try values.encodeIfPresent(reasoningEfforts, forKey: .reasoningEfforts)
        try values.encodeIfPresent(contextWindowTokens, forKey: .contextWindowTokens)
        try values.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        vision = try values.decodeIfPresent(Bool.self, forKey: .vision)
        pricing = try values.decodeIfPresent([String: String].self, forKey: .pricing)
        reasoning = try values.decodeIfPresent(Capabilities.self, forKey: .capabilities)?.reasoning
        reasoningEfforts = try values.decodeIfPresent([String].self, forKey: .reasoningEfforts)
        contextWindowTokens = try values.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        maxOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
    }
}

/// An explicitly cloud-only turn: it cannot advertise or inherit desktop tools.
public struct ChatSendRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var deviceId: String
    public var text: String
    public var image: String?
    public var modelRef: String?
    public var reasoningEffort: String?
    public let tools: [String] = []
    public let platform = "iOS"
    public var timeZone: String
    public var locale: String
    /// Starts a temporary conversation: never listed and deleted when left.
    /// Ignored by the server once the conversation exists.
    public var temporary: Bool?
    public init(id: String = UUID().uuidString, deviceId: String, text: String,
                image: String? = nil, modelRef: String? = nil, reasoningEffort: String? = nil,
                timeZone: String = TimeZone.current.identifier, locale: String = Locale.current.identifier,
                temporary: Bool? = nil) {
        self.id = id; self.deviceId = deviceId; self.text = text
        self.image = image; self.modelRef = modelRef; self.timeZone = timeZone; self.locale = locale
        self.reasoningEffort = reasoningEffort; self.temporary = temporary
    }
}

/// `POST /:id/title`: `rename` sets a manual title; `generate` asks the server to
/// name the conversation once, with its conversation-title model.
public struct ChatTitleRequest: Encodable, Equatable, Sendable {
    public var action: String
    public var id: String?
    public var title: String?

    public static func rename(_ title: String) -> ChatTitleRequest {
        ChatTitleRequest(action: "rename", id: nil, title: title)
    }

    public static func generate(task: String = UUID().uuidString.lowercased()) -> ChatTitleRequest {
        ChatTitleRequest(action: "generate", id: task, title: nil)
    }
}
