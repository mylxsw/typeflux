import Foundation

/// Wire format shared by the desktop and mobile clients.
public enum ChatCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
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

/// PostgreSQL and legacy snapshots must resolve to the same conversation identity.
@propertyWrapper
public struct ChatConversationID: Codable, Equatable, Sendable {
    private var value: String
    public var wrappedValue: String {
        get { value }
        set { value = Self.canonical(newValue) }
    }
    public init(wrappedValue: String) { value = Self.canonical(wrappedValue) }
    public init(from decoder: Decoder) throws {
        value = Self.canonical(try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    public static func canonical(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString.lowercased() ?? id
    }
    public static func legacy(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }
}
