import CryptoKit
import Foundation

/// Hashes and HMACs the services' request signatures are made of.
enum AskTranslationSigning {
    static func sha256Hex(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func md5Hex(_ text: String) -> String { hex(Insecure.MD5.hash(data: Data(text.utf8))) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hmacHex(_ key: Data, _ message: String) -> String { hex(hmac(key, message)) }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// "20260601T120000Z" or "2026-06-01" in UTC.
    static func utc(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// `application/x-www-form-urlencoded` with every reserved character escaped.
    static func formBody(_ fields: [(String, String)]) -> Data {
        // ASCII only: `CharacterSet.alphanumerics` would let other scripts through unescaped.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension AskTranslationLanguages {
    /// A service's code for `language`, looked up by its base ("zh-hans", "en").
    static func serviceCode(_ language: String, in table: [String: String]) -> String? {
        table[base(language)]
    }
}
