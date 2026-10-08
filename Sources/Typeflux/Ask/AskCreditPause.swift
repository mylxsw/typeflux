import Foundation

/// The card a run paused for credits shows: what is left of the month and of the
/// add-on pool, and the one next step. Pure, so every state is testable.
struct AskCreditPausePresentation: Equatable {
    enum State: Equatable {
        /// Monthly and add-on credits are both used up.
        case exhausted
        /// The balance came back; the run can continue from its checkpoint.
        case available
    }

    enum Action: Equatable {
        case buyCredits
        case upgradePlan
        case continueRun
    }

    let state: State
    /// Nil while the balance is not known yet.
    let monthlyRemaining: Int?
    let addonRemaining: Int?
    let primary: Action?
    let secondary: Action?
    /// The latest `resume` found the balance still empty.
    let confirmedByServer: Bool
    let periodEnd: Date?

    /// Nil unless the run is paused for credits and nothing is resuming it.
    /// `details` (from the latest `resume`) wins over `credits` until the balance
    /// is refreshed, which clears them.
    init?(run: AskRun?, busy: Bool, credits: CloudCreditSummary?, details: CloudCreditsExhaustedDetails?,
          subscription: BillingSubscriptionSnapshot, usagePeriodEnd: String?) {
        guard run?.isPausedForCredits == true, !busy else { return nil }
        let available = details == nil && credits?.canSpend == true
        state = available ? .available : .exhausted
        confirmedByServer = details != nil
        if let details {
            monthlyRemaining = max(0, details.monthlyRemaining)
            addonRemaining = max(0, details.addonRemaining)
        } else if let credits, !credits.unlimited {
            monthlyRemaining = credits.monthlyRemaining
            addonRemaining = credits.addonRemaining
        } else {
            monthlyRemaining = nil
            addonRemaining = nil
        }
        periodEnd = (details?.periodEnd ?? usagePeriodEnd).flatMap(ISO8601DateFormatter.typefluxBillingDate(from:))
        if available {
            primary = .continueRun
            secondary = nil
        } else if details?.purchasable ?? subscription.billingEnabled {
            primary = .buyCredits
            secondary = .upgradePlan
        } else {
            // Without billing the allowance only comes back when the period resets.
            primary = nil
            secondary = nil
        }
    }

    var titleKey: String {
        state == .available ? "ask.credits.available.title" : "ask.credits.exhausted.title"
    }

    var bodyKey: String {
        switch state {
        case .available:
            return "ask.credits.available.body"
        case .exhausted where primary == nil:
            return periodEnd == nil ? "ask.credits.exhausted.waitBody" : "ask.credits.exhausted.waitUntilBody"
        case .exhausted where confirmedByServer:
            return "ask.credits.exhausted.stillBody"
        case .exhausted:
            return "ask.credits.exhausted.body"
        }
    }

    static func titleKey(_ action: Action) -> String {
        switch action {
        case .buyCredits: "ask.credits.buy"
        case .upgradePlan: "ask.credits.upgrade"
        case .continueRun: "ask.credits.continue"
        }
    }

    static func symbol(_ action: Action) -> String {
        switch action {
        case .buyCredits: "cart.fill"
        case .upgradePlan: "sparkles"
        case .continueRun: "play.fill"
        }
    }
}
