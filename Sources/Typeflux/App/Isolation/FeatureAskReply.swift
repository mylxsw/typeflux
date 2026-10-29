import Foundation
import TypefluxChat

struct FeatureAskReply: Codable, Sendable {
    let payload: Data?
    let error: FeatureAskError?
}

/// Preserve error categories used by account, credit and recovery flows.
/// Transport failure is separate from a completed API call returning an error.
struct FeatureAskError: Codable, Sendable {
    enum Kind: String, Codable { case cancelled, unauthorized, server, invalidResponse, unavailable, credits, recovery, network, message }
    let kind: Kind
    let code: String?
    let message: String?
    let monthly: Double?
    let addon: Double?
    let period: String?
    let purchasable: Bool?

    init(_ error: Error) {
        var kind: Kind = .message
        var code: String?
        var message: String? = error.localizedDescription
        var details: CloudCreditsExhaustedDetails?
        if error is CancellationError { kind = .cancelled }
        else if let urlError = error as? URLError { kind = .network; code = String(urlError.code.rawValue) }
        else if let recovery = error as? AskRecoveryError {
            kind = .recovery
            switch recovery { case .unknown: code = "unknown"; case .binding: code = "binding"; case .storage: code = "storage" }
        }
        else if let credits = error as? CloudCreditsExhaustedError { kind = .credits; details = credits.details }
        else if let auth = error as? AuthError {
            switch auth {
            case .unauthorized: kind = .unauthorized
            case let .serverError(value, text): kind = .server; code = value; message = text
            case .invalidResponse: kind = .invalidResponse
            case .networkError: kind = .unavailable
            }
        } else if let api = error as? ChatAPIError {
            switch api {
            case .unauthorized: kind = .unauthorized
            case let .server(value, text): kind = .server; code = value; message = text
            case .invalidResponse: kind = .invalidResponse
            case .unavailable: kind = .unavailable
            }
        }
        self.kind = kind; self.code = code; self.message = message
        monthly = details?.monthlyRemaining; addon = details?.addonRemaining
        period = details?.periodEnd; purchasable = details?.purchasable
    }

    var restored: Error {
        switch kind {
        case .cancelled: return CancellationError()
        case .unauthorized: return AuthError.unauthorized
        case .server: return ChatAPIError.server(code: code ?? "", message: message)
        case .invalidResponse: return ChatAPIError.invalidResponse
        case .unavailable: return ChatAPIError.unavailable
        case .credits:
            let details = monthly.map { CloudCreditsExhaustedDetails(monthlyRemaining: $0,
                addonRemaining: addon ?? 0, periodEnd: period, purchasable: purchasable ?? false) }
            return CloudCreditsExhaustedError(details: details)
        case .recovery: return code == "unknown" ? AskRecoveryError.unknown : code == "binding" ? AskRecoveryError.binding : AskRecoveryError.storage
        case .network: return URLError(URLError.Code(rawValue: Int(code ?? "") ?? URLError.unknown.rawValue))
        case .message: return AskLocalError.message(message ?? "")
        }
    }
}
