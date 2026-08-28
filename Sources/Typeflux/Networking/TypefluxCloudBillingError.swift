import Foundation

struct TypefluxCloudBillingError: LocalizedError, Equatable {
    enum Reason: Equatable {
        case subscriptionRequired
        case quotaExceeded
    }

    enum PrimaryAction: Equatable {
        case openAccount
        case openPlans
    }

    let reason: Reason
    let serverMessage: String?

    var errorDescription: String? {
        switch reason {
        case .subscriptionRequired:
            L("cloud.billing.subscriptionRequired.body")
        case .quotaExceeded:
            L("cloud.billing.quotaExceeded.body")
        }
    }

    var title: String {
        switch reason {
        case .subscriptionRequired:
            L("cloud.billing.subscriptionRequired.title")
        case .quotaExceeded:
            L("cloud.billing.quotaExceeded.title")
        }
    }

    func title(hasPaidSubscription: Bool, billingEnabled: Bool = true) -> String {
        if !billingEnabled {
            return L("cloud.billing.freeQuotaExceeded.title")
        }
        switch reason {
        case .subscriptionRequired:
            return L("cloud.billing.subscriptionRequired.title")
        case .quotaExceeded:
            return hasPaidSubscription
                ? L("cloud.billing.quotaExceeded.title")
                : L("cloud.billing.freePlanQuotaExceeded.title")
        }
    }

    func message(hasPaidSubscription: Bool, billingEnabled: Bool = true) -> String {
        if !billingEnabled {
            return L("cloud.billing.freeQuotaExceeded.body")
        }
        switch reason {
        case .subscriptionRequired:
            return L("cloud.billing.subscriptionRequired.body")
        case .quotaExceeded:
            return hasPaidSubscription
                ? L("cloud.billing.quotaExceeded.body")
                : L("cloud.billing.freePlanQuotaExceeded.body")
        }
    }

    var primaryActionTitle: String {
        primaryActionTitle(hasPaidSubscription: false)
    }

    func primaryActionTitle(hasPaidSubscription: Bool, billingEnabled: Bool = true) -> String {
        if primaryAction(hasPaidSubscription: hasPaidSubscription, billingEnabled: billingEnabled) == .openAccount {
            return L("cloud.billing.action.openAccount")
        }
        switch reason {
        case .subscriptionRequired:
            return L("cloud.billing.action.subscribe")
        case .quotaExceeded:
            return L("cloud.billing.action.upgradePlan")
        }
    }

    func primaryAction(hasPaidSubscription: Bool, billingEnabled: Bool = true) -> PrimaryAction {
        guard billingEnabled else { return .openAccount }
        switch reason {
        case .subscriptionRequired:
            return .openPlans
        case .quotaExceeded:
            return hasPaidSubscription ? .openAccount : .openPlans
        }
    }

    static func fromServerCode(_ code: String, message: String?) -> TypefluxCloudBillingError? {
        let normalizedCode = normalized(code)
        if subscriptionRequiredCodes.contains(normalizedCode) {
            return TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: message)
        }
        if quotaExceededCodes.contains(normalizedCode) || normalizedCode.hasSuffix("_QUOTA_EXCEEDED") {
            return TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: message)
        }
        return nil
    }

    static func fromHTTPStatus(_ statusCode: Int, bodyData: Data) -> TypefluxCloudBillingError? {
        if let envelope = try? JSONDecoder().decode(BillingErrorEnvelope.self, from: bodyData),
           let error = fromServerCode(envelope.code, message: envelope.message) {
            return error
        }

        let body = String(data: bodyData, encoding: .utf8) ?? ""
        if let error = fromMessage(body) {
            return error
        }

        guard statusCode == 402 else { return nil }
        return TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: body)
    }

    static func fromError(_ error: Error) -> TypefluxCloudBillingError? {
        if let billingError = error as? TypefluxCloudBillingError {
            return billingError
        }

        if let routingError = error as? TypefluxOfficialASRRoutingError,
           case let .serverError(code, message) = routingError {
            return fromServerCode(code, message: message)
        }

        if let asrError = error as? TypefluxOfficialASRError,
           case let .serverError(message) = asrError {
            return fromMessage(message)
        }

        let nsError = error as NSError
        if let response = nsError.userInfo["NSErrorFailingURLResponseKey"] as? HTTPURLResponse,
           response.statusCode == 402 {
            return TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nsError.localizedDescription)
        }
        if nsError.code == 402, let error = fromMessage(error.localizedDescription) {
            return error
        }
        return fromMessage(error.localizedDescription)
    }

    static func fromMessage(_ message: String) -> TypefluxCloudBillingError? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(BillingErrorEnvelope.self, from: data),
           let error = fromServerCode(envelope.code, message: envelope.message) {
            return error
        }

        if let jsonStart = trimmed.firstIndex(of: "{") {
            let jsonText = String(trimmed[jsonStart...])
            if let data = jsonText.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(BillingErrorEnvelope.self, from: data),
               let error = fromServerCode(envelope.code, message: envelope.message) {
                return error
            }
        }

        let normalizedMessage = normalized(trimmed)
        if subscriptionRequiredCodes.contains(where: { normalizedMessage.contains($0) })
            || normalizedMessage.contains("ACTIVE_SUBSCRIPTION_REQUIRED")
            || normalizedMessage.contains("SUBSCRIPTION_REQUIRED")
            || normalizedMessage.contains("PLAN_REQUIRED") {
            return TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: message)
        }

        if quotaExceededCodes.contains(where: { normalizedMessage.contains($0) })
            || normalizedMessage.contains("QUOTA_EXCEEDED")
            || normalizedMessage.contains("CREDIT_BALANCE_EXHAUSTED")
            || normalizedMessage.contains("CREDIT_EXHAUSTED")
            || normalizedMessage.contains("INSUFFICIENT_CREDITS") {
            return TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: message)
        }

        return nil
    }

    private static let subscriptionRequiredCodes: Set<String> = [
        "PLAN_REQUIRED",
        "SUBSCRIPTION_REQUIRED",
        "PAYMENT_REQUIRED",
        "BILLING_PAST_DUE",
        "INVOICE_PAST_DUE",
        "INVOICE_UNPAID",
        "SUBSCRIPTION_PAST_DUE",
        "SUBSCRIPTION_UNPAID"
    ]

    private static let quotaExceededCodes: Set<String> = [
        "QUOTA_EXCEEDED",
        "ASR_QUOTA_EXCEEDED",
        "LLM_QUOTA_EXCEEDED",
        "INSUFFICIENT_CREDITS",
        "CREDIT_BALANCE_EXHAUSTED",
        "CREDIT_EXHAUSTED"
    ]

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()
    }
}

private struct BillingErrorEnvelope: Decodable {
    let code: String
    let message: String?
}

struct TypefluxCloudIntegratedRewriteError: LocalizedError {
    let transcript: String
    let underlyingError: Error

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}
