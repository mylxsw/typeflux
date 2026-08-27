import Foundation

enum CloudDataLocalScope {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = "guest"

    static var key: String {
        lock.withLock { value }
    }

    static func useGuest() {
        lock.withLock { value = "guest" }
    }

    static func useAccount(_ userID: String) {
        lock.withLock { value = "user.\(userID)" }
    }
}

enum CloudSyncEntityType: String, Codable {
    case vocabulary
    case persona
}

struct CloudSyncMutation: Codable, Equatable {
    let mutationID: UUID
    let entityType: CloudSyncEntityType
    let entityID: UUID
    let operation: String
    let baseRevision: Int64
    let payload: Data

    private enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case operation
        case baseRevision = "base_revision"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(operation, forKey: .operation)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(JSONValue(data: payload), forKey: .payload)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mutationID == rhs.mutationID && lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID && lhs.operation == rhs.operation
            && lhs.baseRevision == rhs.baseRevision && lhs.payload == rhs.payload
    }
}

struct CloudSyncRequest: Encodable {
    let protocolVersion = 1
    let deviceID: UUID
    let cursor: Int64
    let ackCursor: Int64
    let checkpoint: Int64
    let limit = 200
    let mutations: [CloudSyncMutation]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceID = "device_id"
        case cursor
        case ackCursor = "ack_cursor"
        case checkpoint
        case limit
        case mutations
    }
}

struct CloudSyncResponse: Decodable {
    let cursor: Int64
    let checkpoint: Int64
    let hasMore: Bool
    let results: [CloudSyncMutationResult]
    let changes: [CloudSyncChange]

    private enum CodingKeys: String, CodingKey {
        case cursor, checkpoint, results, changes
        case hasMore = "has_more"
    }
}

struct CloudSyncMutationResult: Decodable {
    let mutationID: UUID
    let status: String
    let entityID: UUID
    let canonicalID: UUID
    let revision: Int64
    let current: JSONValue?
    let deleted: Bool
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id"
        case status
        case entityID = "entity_id"
        case canonicalID = "canonical_id"
        case revision, current, deleted, message
    }

    init(
        mutationID: UUID, status: String, entityID: UUID, canonicalID: UUID,
        revision: Int64, current: JSONValue?, deleted: Bool = false, message: String? = nil
    ) {
        self.mutationID = mutationID
        self.status = status
        self.entityID = entityID
        self.canonicalID = canonicalID
        self.revision = revision
        self.current = current
        self.deleted = deleted
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
        status = try container.decode(String.self, forKey: .status)
        entityID = try container.decode(UUID.self, forKey: .entityID)
        canonicalID = try container.decodeIfPresent(UUID.self, forKey: .canonicalID) ?? entityID
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        current = try container.decodeIfPresent(JSONValue.self, forKey: .current)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

struct CloudSyncChange: Decodable {
    let sequence: Int64
    let entityType: CloudSyncEntityType
    let entityID: UUID
    let operation: String
    let revision: Int64
    let payload: JSONValue

    private enum CodingKeys: String, CodingKey {
        case sequence
        case entityType = "entity_type"
        case entityID = "entity_id"
        case operation, revision, payload
    }
}

struct VocabularyCloudPayload: Codable {
    let term: String
    let source: String
    let createdAt: Date
    let occurrenceCount: Int

    private enum CodingKeys: String, CodingKey {
        case term, source
        case createdAt = "created_at"
        case occurrenceCount = "occurrence_count"
    }
}

struct PersonaCloudPayload: Codable {
    let name: String
    let prompt: String
}

struct JSONValue: Codable {
    let data: Data

    init(data: Data) { self.data = data }

    init(from decoder: Decoder) throws {
        let value = try SyncJSONAny(from: decoder)
        data = try JSONSerialization.data(withJSONObject: value.value)
    }

    func encode(to encoder: Encoder) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        try SyncJSONAny(object).encode(to: encoder)
    }
}

private struct SyncJSONAny: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let value = try? container.decode(Bool.self) { self.value = value }
        else if let value = try? container.decode(Int.self) { self.value = value }
        else if let value = try? container.decode(Double.self) { self.value = value }
        else if let value = try? container.decode(String.self) { self.value = value }
        else if let value = try? container.decode([SyncJSONAny].self) { self.value = value.map(\.value) }
        else if let value = try? container.decode([String: SyncJSONAny].self) {
            self.value = value.mapValues(\.value)
        } else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [Any]: try container.encode(value.map(SyncJSONAny.init))
        case let value as [String: Any]: try container.encode(value.mapValues(SyncJSONAny.init))
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid JSON")
            )
        }
    }
}
