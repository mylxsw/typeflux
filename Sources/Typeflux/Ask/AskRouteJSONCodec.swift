import Foundation

/// Exact decimal coefficient/exponent identity without a floating point conversion.
struct AskRouteNumber: Equatable, Sendable, ExpressibleByIntegerLiteral {
    let token: String
    private let identity: String

    init(integerLiteral value: Int) {
        self.init(String(value))
    }

    init(_ token: String) {
        self.token = token
        let parts = token.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = parts[0]
        let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        var digits = mantissa.filter(\.isNumber)
        while digits.first == "0" {
            digits.removeFirst()
        }
        if digits.isEmpty {
            identity = "0"; return
        }
        var adjustment = -(fraction.count == 2 ? fraction[1].count : 0)
        while digits.last == "0" {
            digits.removeLast(); adjustment += 1
        }
        let exponent = Self.add(parts.count == 2 ? String(parts[1]) : "0", adjustment)
        identity = (mantissa.first == "-" ? "-" : "") + digits + "e" + exponent
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
    }

    var integer: Int? {
        guard let split = identity.firstIndex(of: "e") else { return identity == "0" ? 0 : nil }
        let coefficient = String(identity[..<split])
        guard let exponent = Int(identity[identity.index(after: split)...]),
              (0 ... 19).contains(exponent) else { return nil }
        return Int(coefficient + String(repeating: "0", count: exponent))
    }

    /// Add a small signed offset to an arbitrarily large JSON exponent.
    private static func add(_ text: String, _ offset: Int) -> String {
        var negative = text.first == "-"
        var digits = text.filter(\.isNumber).drop(while: { $0 == "0" }).map { Int(String($0))! }
        if digits.isEmpty {
            digits = [0]; negative = false
        }
        if offset != 0 {
            for _ in 0 ..< abs(offset) {
                if negative == (offset < 0) {
                    var index = digits.count - 1
                    while index > 0, digits[index] == 9 {
                        digits[index] = 0; index -= 1
                    }
                    digits[index] += 1
                    if digits[0] == 10 {
                        digits[0] = 0; digits.insert(1, at: 0)
                    }
                } else if digits == [0] {
                    negative = offset < 0; digits = [1]
                } else {
                    var index = digits.count - 1
                    while digits[index] == 0 {
                        digits[index] = 9; index -= 1
                    }
                    digits[index] -= 1
                    if digits.count > 1, digits[0] == 0 {
                        digits.removeFirst()
                    }
                    if digits == [0] {
                        negative = false
                    }
                }
            }
        }
        return (negative ? "-" : "") + digits.map(String.init).joined()
    }
}

extension AskRouteJSON {
    /// Only this scoped codec is used at private snapshot evidence boundaries.
    static func decodeRaw(_ data: Data) throws -> Self {
        var parser = AskRouteJSONParser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    func encodeRaw() throws -> Data {
        switch self {
        case .null: return Data("null".utf8)
        case let .bool(value): return Data((value ? "true" : "false").utf8)
        case let .number(value): return Data(value.token.utf8)
        case let .string(value): return try JSONEncoder().encode(value)
        case let .array(values):
            var data = Data("[".utf8)
            for (index, value) in values.enumerated() {
                if index > 0 {
                    data.append(44)
                }
                try data.append(value.encodeRaw())
            }
            data.append(93)
            return data
        case let .object(values):
            var data = Data("{".utf8)
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 {
                    data.append(44)
                }
                try data.append(JSONEncoder().encode(key))
                data.append(58)
                try data.append(values[key]!.encodeRaw())
            }
            data.append(125)
            return data
        }
    }
}

private struct AskRouteJSONParser {
    let bytes: [UInt8]
    var index = 0
    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() throws -> String {
        whitespace()
        let start = index
        guard consume(34) else { throw CocoaError(.coderReadCorrupt) }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 {
                index += 1
            }
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    mutating func value(depth: Int) throws -> AskRouteJSON {
        whitespace()
        guard depth < 512, index < bytes.count else { throw CocoaError(.coderReadCorrupt) }
        if bytes[index] == 34 {
            return try .string(string())
        }
        if consume(123) {
            return try object(depth: depth)
        }
        if consume(91) {
            return try array(depth: depth)
        }
        return try scalar()
    }

    private mutating func object(depth: Int) throws -> AskRouteJSON {
        var fields: [String: AskRouteJSON] = [:]
        if consume(125) {
            return .object(fields)
        }
        repeat {
            let key = try string()
            guard consume(58) else { throw CocoaError(.coderReadCorrupt) }
            fields[key] = try value(depth: depth + 1)
            if consume(125) {
                return .object(fields)
            }
        } while consume(44)
        throw CocoaError(.coderReadCorrupt)
    }

    private mutating func array(depth: Int) throws -> AskRouteJSON {
        var values: [AskRouteJSON] = []
        if consume(93) {
            return .array(values)
        }
        repeat {
            try values.append(value(depth: depth + 1))
            if consume(93) {
                return .array(values)
            }
        } while consume(44)
        throw CocoaError(.coderReadCorrupt)
    }

    private mutating func scalar() throws -> AskRouteJSON {
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
            index += 1
        }
        guard let token = String(bytes: bytes[start ..< index], encoding: .utf8)
        else { throw CocoaError(.coderReadCorrupt) }
        switch token {
        case "null": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            guard token
                .range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            return .number(.init(token))
        }
    }
}

extension AskLocalRecord {
    static func decodeSnapshot(_ data: Data) throws -> Self {
        guard case var .object(root) = try AskRouteJSON.decodeRaw(data) else { throw CocoaError(.coderReadCorrupt) }
        let archive = root.removeValue(forKey: "agent_routes")
        var binding: AskRouteJSON?
        if case var .object(conversation) = root["conversation"], case var .object(run) = conversation["run"] {
            binding = run.removeValue(forKey: "agent_binding")
            conversation["run"] = .object(run)
            root["conversation"] = .object(conversation)
        }
        var record = try AskCoding.decoder().decode(Self.self, from: AskRouteJSON.object(root).encodeRaw())
        record.agentRoutes = archive.map(AskRunRouteArchive.init(raw:))
        record.conversation.run?.agentBinding = binding.flatMap { $0 == .null ? nil : AskAgentBinding(raw: $0) }
        return record
    }

    func encodeSnapshot() throws -> Data {
        // Remove private evidence before Foundation encoding; reinsert exact tokens afterwards.
        var copy = self
        copy.agentRoutes = nil
        copy.conversation.run?.agentBinding = nil
        guard case var .object(root) = try AskRouteJSON.decodeRaw(AskCoding.encoder().encode(copy))
        else { throw CocoaError(.coderInvalidValue) }
        root["agent_routes"] = agentRoutes?.raw
        if case var .object(conversation) = root["conversation"], case var .object(run) = conversation["run"] {
            run["agent_binding"] = self.conversation.run?.agentBinding?.routeEvidence
            conversation["run"] = .object(run)
            root["conversation"] = .object(conversation)
        }
        return try AskRouteJSON.object(root).encodeRaw()
    }
}
