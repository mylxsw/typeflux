import Foundation

/// Adapter protocol identity, independent of model and local/cloud placement.
/// Older binaries cannot safely own future nondefault runs. Alternate selection
/// stays disabled until negotiated rolling-upgrade compatibility is implemented.
struct AskAgentBinding: Codable, Equatable, Sendable {
    var id: String
    var version: Int
    private var invalid: AskRouteJSON?
    private var original: AskRouteJSON?

    static let `default` = Self(id: "typeflux.default", version: 1)
    static let errorCode = "AGENT_IMPLEMENTATION_UNAVAILABLE"

    init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// Registry identity retains its existing id/version semantics. The archive
    /// compares the complete encoded JSON separately, including extension fields.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version && lhs.invalid == rhs.invalid
    }

    /// Legacy absence resolves without modifying the persisted representation.
    static func resolve(_ binding: Self?) throws -> Self {
        guard let binding else { return .default }
        guard AskAgentDescriptor.default.supports(binding, requiredOperations: []) else {
            throw AskLocalError.implementationUnavailable
        }
        return binding
    }

    /// ASCII letters/digits followed by letters/digits, dot, underscore or hyphen.
    var isWellFormed: Bool {
        guard invalid == nil, version > 0, !id.isEmpty else { return false }
        return id.utf8.enumerated().allSatisfy { index, byte in
            let alphanumeric = (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte)
            return alphanumeric || (index > 0 && [46, 95, 45].contains(byte))
        }
    }

    private enum CodingKeys: String, CodingKey { case id, version }

    init(raw: AskRouteJSON) {
        if case let .object(fields) = raw, case let .string(id) = fields["id"],
           case let .number(number) = fields["version"], let version = number.integer {
            self.id = id
            self.version = version
            original = raw
        } else {
            id = ""
            version = 0
            invalid = raw
        }
    }

    var routeEvidence: AskRouteJSON {
        if let invalid {
            return invalid
        }
        var fields: [String: AskRouteJSON] = [:]
        if case let .object(original) = original {
            fields = original
        }
        fields["id"] = .string(id)
        fields["version"] = .number(.init(String(version)))
        return .object(fields)
    }

    init(from decoder: Decoder) throws {
        // Keep existing typed wire admission. Private snapshot evidence is
        // restored from original bytes by decodeSnapshot before it is used.
        if let values = try? decoder.container(keyedBy: CodingKeys.self),
           let id = try? values.decode(String.self, forKey: .id),
           let version = try? values.decode(Int.self, forKey: .version) {
            self.id = id
            self.version = version
            original = try AskRouteJSON(from: decoder)
        } else {
            id = ""
            version = 0
            invalid = try AskRouteJSON(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        if let invalid {
            try invalid.encode(to: encoder); return
        }
        if case var .object(fields) = original {
            fields["id"] = .string(id)
            fields["version"] = .number(.init(String(version)))
            try AskRouteJSON.object(fields).encode(to: encoder)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
    }
}
