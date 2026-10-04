import Foundation

public struct ChatSession: Decodable, Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Int
    public let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenCamel = "accessToken"
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
        case expiresIn = "expires_in"
        case expiresInCamel = "expiresIn"
        case refreshToken = "refresh_token"
        case refreshTokenCamel = "refreshToken"
    }

    public init(accessToken: String, expiresAt: Int, refreshToken: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeFirstString(for: [.accessToken, .accessTokenCamel])
        expiresAt = try container.decodeFirstInt(for: [.expiresAt, .expiresAtCamel, .expiresIn, .expiresInCamel])
        refreshToken = try container.decodeFirstStringIfPresent(for: [.refreshToken, .refreshTokenCamel])
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstString(for keys: [Key]) throws -> String {
        for key in keys where contains(key) {
            return try decode(String.self, forKey: key)
        }
        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected one of \(keys.map(\.stringValue))"
            )
        )
    }

    func decodeFirstStringIfPresent(for keys: [Key]) throws -> String? {
        for key in keys where contains(key) {
            return try decodeIfPresent(String.self, forKey: key)
        }
        return nil
    }

    func decodeFirstInt(for keys: [Key]) throws -> Int {
        for key in keys where contains(key) {
            if let value = try? decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? decode(Double.self, forKey: key),
               value.isFinite, value >= Double(Int.min), value < Double(Int.max) {
                return Int(value)
            }
            if let value = try? decode(String.self, forKey: key), let intValue = Int(value) {
                return intValue
            }
        }
        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected one of \(keys.map(\.stringValue))"
            )
        )
    }
}
