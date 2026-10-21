import Foundation

/// Internal host composition only; evidence never grants permission to execute.
protocol AskRunRouteAccess: Sendable {
    func runRoute(conversationId: String, runId: String) async throws -> AskRunRouteLookup
}

struct AskRunRoute: Equatable, Sendable {
    let runID: String
    let deviceID: String
    let binding: AskRouteJSON
}

enum AskRunRouteLookup: Equatable, Sendable {
    enum Source: Equatable, Sendable { case archived, currentSnapshot }
    case found(AskRunRoute, source: Source)
    case unrecorded
    case unavailable
}

/// Local JSON value semantics, including scalar/null roots. Do not use the sync
/// JSONValue implementation, whose serialization assumes object/array roots.
/// Foundation Codable is a compatibility adapter, not a numeric token source.
/// Private snapshots must use decodeSnapshot/encodeSnapshot and the raw codec.
indirect enum AskRouteJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(AskRouteNumber), string(String), array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let item = try? value.decode(Bool.self) {
            self = .bool(item)
        } else if let item = try? value.decode(Decimal.self) {
            self = .number(.init(NSDecimalNumber(decimal: item).stringValue))
        } else if let item = try? value.decode(Double.self) {
            self = .number(.init(String(item)))
        } else if let item = try? value.decode(String.self) {
            self = .string(item)
        } else if let item = try? value.decode([Self].self) {
            self = .array(item)
        } else {
            self = try .object(value.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(item): try value.encode(item)
        case let .number(item):
            if let number = Decimal(string: item.token),
               AskRouteNumber(NSDecimalNumber(decimal: number).stringValue) == item {
                try value.encode(number)
            } else if let number = Double(item.token), number.isFinite, AskRouteNumber(String(number)) == item {
                try value.encode(number)
            } else {
                throw CocoaError(.coderInvalidValue)
            }
        case let .string(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        }
    }

    static let defaultBinding: Self = .object(["id": .string("typeflux.default"), "version": .number(1)])
    static func effectiveBinding(_ value: Self?) -> Self {
        guard let value, value != .null else { return .defaultBinding }
        return value
    }
}

/// Private persistence value. Invalid JSON shapes remain opaque and readable.
/// Entries live until conversation deletion, independent of message/retry count.
struct AskRunRouteArchive: Codable, Equatable, Sendable {
    var raw: AskRouteJSON
    init(raw: AskRouteJSON) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try AskRouteJSON(from: decoder) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    private var entries: [String: AskRouteJSON]? {
        guard case let .object(root) = raw, root["version"] == .number(1),
              case let .object(entries) = root["runs"] else { return nil }
        for (id, value) in entries {
            guard Self.route(id: id, value: value) != nil else { return nil }
        }
        return entries
    }

    private static func route(id: String, value: AskRouteJSON) -> AskRunRoute? {
        guard !id.isEmpty, id.utf8.count <= 128, case let .object(object) = value,
              case let .string(device) = object["device_id"] else { return nil }
        return .init(runID: id, deviceID: device, binding: .effectiveBinding(object["agent_binding"]))
    }

    private static func route(_ run: AskRun?) throws -> AskRunRoute? {
        guard let run else { return nil }
        let raw = run.agentBinding?.routeEvidence
        guard !run.id.isEmpty, run.id.utf8.count <= 128 else { throw conflict }
        return .init(runID: run.id, deviceID: run.deviceId, binding: .effectiveBinding(raw))
    }

    private static var conflict: AskLocalError { .message(L("ask.local.conflict")) }

    static func merging(cached: Self?, incoming: Self?, previous: AskRun?, current: AskRun?) throws -> Self? {
        let old = try route(previous), new = try route(current)
        // Invalid archives cannot be replaced by stale known copies or repaired
        // implicitly. Metadata writes preserve them only for the same identity.
        if let cached, cached.entries == nil {
            guard old == new else { throw conflict }
            if let new, let raw = incoming?.entries?[new.runID], Self.route(id: new.runID, value: raw) != new {
                throw conflict
            }
            return cached
        }
        if let incoming, incoming.entries == nil {
            guard cached == nil, old == new else { throw conflict }
            return incoming
        }
        var entries = cached?.entries ?? [:]
        func insert(_ route: AskRunRoute, raw: AskRouteJSON) throws {
            if let prior = entries[route.runID], Self.route(id: route.runID, value: prior) != route { throw conflict }
            if entries[route.runID] == nil { entries[route.runID] = raw }
        }
        for (id, value) in incoming?.entries ?? [:] {
            guard let route = Self.route(id: id, value: value) else { throw conflict }
            try insert(route, raw: value)
        }
        for route in [old, new].compactMap({ $0 }) {
            try insert(route, raw: .object(["device_id": .string(route.deviceID), "agent_binding": route.binding]))
        }
        guard cached != nil || incoming != nil || !entries.isEmpty else { return nil }
        var root: [String: AskRouteJSON] = [:]
        if case let .object(value) = cached?.raw ?? incoming?.raw { root = value }
        root["version"] = .number(1)
        root["runs"] = .object(entries)
        return .init(raw: .object(root))
    }

    static func lookup(archive: Self?, current: AskRun?, runID: String) -> AskRunRouteLookup {
        guard !runID.isEmpty, runID.utf8.count <= 128 else { return .unavailable }
        let entries: [String: AskRouteJSON]
        if let archive {
            guard let valid = archive.entries else { return .unavailable }
            entries = valid
        } else { entries = [:] }
        let snapshot: AskRunRoute?
        do { snapshot = try route(current) } catch { return .unavailable }
        if let snapshot, let raw = entries[snapshot.runID],
           Self.route(id: snapshot.runID, value: raw) != snapshot { return .unavailable }
        let route: AskRunRoute
        let source: AskRunRouteLookup.Source
        if let raw = entries[runID], let archived = Self.route(id: runID, value: raw) {
            route = archived; source = .archived
        } else if let snapshot, snapshot.runID == runID {
            route = snapshot; source = .currentSnapshot
        } else { return .unrecorded }
        guard AskAgentBinding(raw: route.binding).isWellFormed else { return .unavailable }
        return .found(route, source: source)
    }
}
