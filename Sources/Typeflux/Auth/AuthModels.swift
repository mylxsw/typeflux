import Foundation

// MARK: - API Response Envelope

struct APIResponse<T: Decodable>: Decodable {
    let code: String
    let message: String?
    let data: T?
}

// MARK: - Enter Email

struct EnterEmailRequest: Encodable {
    let email: String
}

struct EnterEmailResponse: Decodable {
    let exists: Bool
    let next: String
    let tip: String?
}

// MARK: - Register

struct RegisterRequest: Encodable {
    let email: String
    let password: String
    let name: String?
}

struct RegisterResponse: Decodable {
    let sent: Bool
}

// MARK: - Activate

struct ActivateRequest: Encodable {
    let email: String
    let code: String
}

struct ActivateResponse: Decodable {
    let activated: Bool
}

struct ResendActivationRequest: Encodable {
    let email: String
    let password: String
}

struct ResendActivationResponse: Decodable {
    let sent: Bool
}

// MARK: - Login

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct LoginResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let expiresAt: Int
    let refreshToken: String?

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

    init(accessToken: String, expiresAt: Int, refreshToken: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }

    init(from decoder: Decoder) throws {
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

// MARK: - Password Reset

struct ForgotPasswordRequest: Encodable {
    let email: String
}

struct ForgotPasswordResponse: Decodable {
    let sent: Bool
}

struct ResetPasswordRequest: Encodable {
    let email: String
    let code: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case email, code
        case newPassword = "new_password"
    }
}

struct ResetPasswordResponse: Decodable {
    let reset: Bool
}

struct ChangePasswordRequest: Encodable {
    let oldPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case oldPassword = "old_password"
        case newPassword = "new_password"
    }
}

struct ChangePasswordResponse: Decodable {
    let changed: Bool
}

// MARK: - OAuth

struct OAuthRequest: Encodable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

struct GitHubOAuthRequest: Encodable {
    let code: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
    }
}

// MARK: - Refresh Token

struct RefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

// MARK: - Logout

struct LogoutRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct LogoutResponse: Decodable {
    let loggedOut: Bool

    enum CodingKeys: String, CodingKey {
        case loggedOut = "logged_out"
    }
}

// MARK: - User Profile

struct UserProfile: Codable, Equatable {
    let id: String
    let email: String
    let name: String?
    let status: Int
    let provider: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, email, name, status, provider
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var resolvedDisplayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? email : trimmedName
    }

    var canChangePassword: Bool {
        provider == "password"
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case networkError(Error)
    case serverError(code: String, message: String?)
    case invalidResponse
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .networkError(error):
            error.localizedDescription
        case let .serverError(code, message):
            TypefluxCloudServerErrorMessage.userMessage(
                code: code,
                message: message,
                fallback: L("auth.error.unknown")
            )
        case .invalidResponse:
            L("auth.error.invalidResponse")
        case .unauthorized:
            L("auth.error.unauthorized")
        }
    }

    var authErrorCode: String? {
        switch self {
        case let .serverError(code, _):
            code
        default:
            nil
        }
    }
}

/// A billing link request finished after the session that made it was logged
/// out or replaced. It carries neither the old account's link nor its error;
/// billing callers drop it instead of showing, logging or acting on it.
struct BillingSessionReplacedError: Error, Equatable {}
