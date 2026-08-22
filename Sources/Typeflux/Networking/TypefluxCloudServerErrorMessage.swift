import Foundation

enum TypefluxCloudServerErrorMessage {
    static func userMessage(code: String, message: String?, fallback: String) -> String {
        if let key = localizationKey(for: code) {
            return L(key)
        }

        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedMessage.isEmpty ? fallback : trimmedMessage
    }

    static func localizationKey(for code: String) -> String? {
        let normalizedCode = normalized(code)

        switch normalizedCode {
        case "AUTH_INVALID_CREDENTIALS":
            return "cloud.error.authInvalidCredentials"
        case "AUTH_USER_EXISTS":
            return "cloud.error.authUserExists"
        case "AUTH_USER_NOT_ACTIVE":
            return "cloud.error.authUserNotActive"
        case "AUTH_CODE_INVALID",
             "AUTH_ACTIVATION_CODE_INVALID",
             "AUTH_RESET_CODE_INVALID",
             "AUTH_PASSWORD_RESET_CODE_INVALID":
            return "cloud.error.authCodeInvalid"
        case "AUTH_REFRESH_TOKEN_INVALID", "AUTH_REFRESH_TOKEN_REUSED", "USER_NOT_FOUND", "AUTH_USER_NOT_FOUND":
            return "cloud.error.sessionExpired"
        case "VALIDATION_ERROR", "BAD_REQUEST", "INVALID_REQUEST":
            return "cloud.error.validation"
        case "RATE_LIMITED", "RATE_LIMIT_EXCEEDED", "TOO_MANY_REQUESTS":
            return "cloud.error.rateLimited"
        case "QUOTA_EXCEEDED",
             "ASR_QUOTA_EXCEEDED",
             "LLM_QUOTA_EXCEEDED",
             "INSUFFICIENT_CREDITS",
             "CREDIT_EXHAUSTED":
            return "cloud.error.quotaExceeded"
        case "PLAN_REQUIRED",
             "SUBSCRIPTION_REQUIRED",
             "PAYMENT_REQUIRED",
             "BILLING_PAST_DUE",
             "INVOICE_PAST_DUE",
             "INVOICE_UNPAID",
             "SUBSCRIPTION_PAST_DUE",
             "SUBSCRIPTION_UNPAID":
            return "cloud.error.planRequired"
        case "BILLING_SUBSCRIPTION_EXISTS":
            return "cloud.error.subscriptionExists"
        case "BILLING_CONNECTION_UNAVAILABLE":
            return "cloud.error.billingConnectionUnavailable"
        case "BILLING_SERVICE_UNAVAILABLE", "BILLING_NOT_CONFIGURED":
            return "cloud.error.billingServiceUnavailable"
        case "SERVER_ERROR", "INTERNAL", "INTERNAL_SERVER_ERROR":
            return "cloud.error.server"
        default:
            if normalizedCode.hasSuffix("_RATE_LIMITED") || normalizedCode.hasSuffix("_RATE_LIMIT_EXCEEDED") {
                return "cloud.error.rateLimited"
            }
            if normalizedCode.hasSuffix("_QUOTA_EXCEEDED") {
                return "cloud.error.quotaExceeded"
            }
            return nil
        }
    }

    private static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .uppercased()
    }
}
