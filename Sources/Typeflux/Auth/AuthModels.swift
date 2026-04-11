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

// MARK: - Login

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct LoginResponse: Decodable {
    let accessToken: String
    let expiresAt: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
        case refreshToken = "refresh_token"
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
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case networkError(Error)
    case serverError(code: String, message: String?)
    case invalidResponse
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            error.localizedDescription
        case .serverError(_, let message):
            message ?? L("auth.error.unknown")
        case .invalidResponse:
            L("auth.error.invalidResponse")
        case .unauthorized:
            L("auth.error.unauthorized")
        }
    }

    var authErrorCode: String? {
        switch self {
        case .serverError(let code, _):
            code
        default:
            nil
        }
    }
}
