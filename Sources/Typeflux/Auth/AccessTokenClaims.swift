import Foundation

/// Reads unverified timing claims from a Typeflux Cloud access JWT. Used only
/// to schedule refreshes; the server remains the authority on validity.
enum AccessTokenClaims {
    /// Signed lifetime (`exp - iat`) in seconds, or nil when the token is not
    /// a JWT or lacks a positive lifetime.
    static func lifetime(of token: String) -> TimeInterval? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let issuedAt = claims.iat,
              let expiresAt = claims.exp,
              expiresAt > issuedAt
        else {
            return nil
        }
        return expiresAt - issuedAt
    }

    private struct Claims: Decodable {
        let iat: TimeInterval?
        let exp: TimeInterval?
    }
}
