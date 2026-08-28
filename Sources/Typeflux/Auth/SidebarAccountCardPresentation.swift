import Foundation

struct SidebarAccountCardPresentation: Equatable {
    enum State: Equatable {
        case signedOut
        case loading
        case unavailable
        case account
    }

    enum Action: Equatable {
        case signIn
        case viewDetails
        case upgrade
        case manageBilling
        case resolveBilling
    }

    let state: State
    let action: Action
    let displayName: String?
    let planName: String?
    let credits: CloudCreditSummary?
    let needsAttention: Bool

    static func make(
        isLoggedIn: Bool,
        subscription: BillingSubscriptionSnapshot,
        credits: CloudCreditSummary?,
        subscriptionError: String?,
        usageError: String?,
        displayName: String? = nil
    ) -> SidebarAccountCardPresentation {
        guard isLoggedIn else {
            return SidebarAccountCardPresentation(
                state: .signedOut,
                action: .signIn,
                displayName: nil,
                planName: nil,
                credits: nil,
                needsAttention: false
            )
        }

        let hasResolvedState = subscription.hasSubscription
            || subscription.billingEnabled
            || credits != nil

        guard hasResolvedState else {
            let hasError = subscriptionError != nil || usageError != nil
            return SidebarAccountCardPresentation(
                state: hasError ? .unavailable : .loading,
                action: .viewDetails,
                displayName: normalizedDisplayName(displayName),
                planName: nil,
                credits: nil,
                needsAttention: false
            )
        }

        let needsAttention = subscription.hasSubscription && !subscription.entitled && !subscription.isFreePlan
        let action: Action
        if needsAttention {
            action = .resolveBilling
        } else if subscription.hasPaidSubscription {
            action = .manageBilling
        } else if subscription.billingEnabled {
            action = .upgrade
        } else {
            action = .viewDetails
        }

        return SidebarAccountCardPresentation(
            state: .account,
            action: action,
            displayName: normalizedDisplayName(displayName),
            planName: displayPlanName(for: subscription),
            credits: credits,
            needsAttention: needsAttention
        )
    }

    var creditPresentation: AccountUsageCreditPresentation {
        AccountUsageCreditPresentation(credits: credits)
    }

    var progress: Double? {
        creditPresentation.progress
    }

    var usesFilledIdentityIcon: Bool {
        state != .signedOut
    }

    private static func displayPlanName(for subscription: BillingSubscriptionSnapshot) -> String {
        let code = subscription.planCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if code?.lowercased() == "free" {
            return "Free"
        }
        if code?.lowercased() == BillingPlan.defaultPlanCode {
            return "Pro"
        }
        if let name = subscription.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let code, !code.isEmpty {
            return code.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "Typeflux Cloud"
    }

    private static func normalizedDisplayName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
