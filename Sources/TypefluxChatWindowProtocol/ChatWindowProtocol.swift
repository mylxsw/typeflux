import Foundation

public enum ChatWindowFailure: Error, Equatable, Sendable {
    case invalidProtocol, unavailable, timedOut, cancelled, busy
}

/// Presentation-only data. No tokens, tools, approvals, storage paths or executor.
public struct ChatWindowSnapshot: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case user, assistant, system }
        public var role: Role
        public var text: String
        public init(role: Role, text: String) { self.role = role; self.text = text }
    }
    public var sequence: UInt64
    public var title: String
    public var messages: [Message]
    public init(sequence: UInt64, title: String, messages: [Message]) {
        self.sequence = sequence; self.title = title; self.messages = messages
    }
    public func validate() throws {
        guard sequence > 0, title.utf8.count <= 512, messages.count <= 512,
              messages.allSatisfy({ $0.text.utf8.count <= 64 * 1024 }),
              messages.reduce(0, { $0 + $1.text.utf8.count }) <= 256 * 1024 else {
            throw ChatWindowFailure.invalidProtocol
        }
    }
}

public struct ChatWindowEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hello, present, ping, hide, shutdown, ready, acknowledged, pong }
    public var version = 1
    public var generation: UUID
    public var id: UUID
    public var kind: Kind
    public var snapshot: ChatWindowSnapshot?
    public var sequence: UInt64?
    public init(generation: UUID, id: UUID = UUID(), kind: Kind, snapshot: ChatWindowSnapshot? = nil, sequence: UInt64? = nil) {
        self.generation = generation; self.id = id; self.kind = kind; self.snapshot = snapshot; self.sequence = sequence
    }
    public func validate() throws {
        guard version == 1, (kind == .present) == (snapshot != nil),
              sequence == nil || (kind == .acknowledged && sequence! > 0) else { throw ChatWindowFailure.invalidProtocol }
        try snapshot?.validate()
    }
}

/// Confines an inherited connection to one launch/account generation and rejects
/// stale presentation updates. No command here can submit or resume a model run.
public struct ChatWindowSession {
    public private(set) var generation: UUID?
    public private(set) var sequence: UInt64 = 0
    public private(set) var stopped = false
    public init() {}
    public mutating func accept(_ request: ChatWindowEnvelope) throws -> ChatWindowEnvelope {
        try request.validate()
        guard !stopped else { throw ChatWindowFailure.unavailable }
        if generation == nil {
            guard request.kind == .hello else { throw ChatWindowFailure.invalidProtocol }
            generation = request.generation
            return .init(generation: request.generation, id: request.id, kind: .ready)
        }
        guard generation == request.generation else { throw ChatWindowFailure.invalidProtocol }
        var reply = ChatWindowEnvelope(generation: request.generation, id: request.id, kind: .acknowledged)
        switch request.kind {
        case .present:
            guard let snapshot = request.snapshot, snapshot.sequence > sequence else { throw ChatWindowFailure.invalidProtocol }
            sequence = snapshot.sequence; reply.sequence = sequence
        case .ping: reply.kind = .pong
        case .hide: break
        case .shutdown: stopped = true
        default: throw ChatWindowFailure.invalidProtocol
        }
        return reply
    }
}
