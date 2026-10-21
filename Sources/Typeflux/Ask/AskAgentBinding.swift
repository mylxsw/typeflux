import Foundation

/// Adapter protocol identity, independent of model and local/cloud placement.
/// Older binaries cannot safely own future nondefault runs. Alternate selection
/// stays disabled until negotiated rolling-upgrade compatibility is implemented.
struct AskAgentBinding: Codable, Equatable, Sendable {
    var id: String
    var version: Int
    private var invalid: Raw?

    static let `default` = Self(id: "typeflux.default", version: 1)
    static let errorCode = "AGENT_IMPLEMENTATION_UNAVAILABLE"

    init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// Legacy absence resolves without modifying the persisted representation.
    static func resolve(_ binding: Self?) throws -> Self {
        guard let binding else { return .default }
        guard binding.invalid == nil, binding.id == Self.default.id, binding.version == 1 else {
            throw AskLocalError.implementationUnavailable
        }
        return binding
    }

    private enum CodingKeys: String, CodingKey { case id, version }

    init(from decoder: Decoder) throws {
        if let values = try? decoder.container(keyedBy: CodingKeys.self),
           let id = try? values.decode(String.self, forKey: .id),
           let version = try? values.decode(Int.self, forKey: .version) {
            self.id = id
            self.version = version
        } else {
            id = ""
            version = 0
            invalid = try Raw(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        if let invalid { try invalid.encode(to: encoder); return }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
    }

    /// Keeps malformed fields readable and intact through metadata-only writes.
    private indirect enum Raw: Codable, Equatable, Sendable {
        case null, bool(Bool), number(Double), string(String), array([Raw]), object([String: Raw])

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([Raw].self) { self = .array(array) }
            else { self = .object(try value.decode([String: Raw].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case let .bool(item): try value.encode(item)
            case let .number(item): try value.encode(item)
            case let .string(item): try value.encode(item)
            case let .array(item): try value.encode(item)
            case let .object(item): try value.encode(item)
            }
        }
    }
}
