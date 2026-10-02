import Foundation

/// What the account surfaces (the Ask sidebar badge, the account card and the
/// account page) show for the signed-in user. Pure, so every state is testable.
struct AccountStatusPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case accent
        case warning
        case danger
    }

    enum Badge: Equatable {
        case plan(String)
        /// Remaining quota, in whole percent, once it drops below the low threshold.
        case low(percent: Int)
        case exhausted
        /// Ask runs on the user's own models (local mode).
        case ownModels
    }

    enum QuotaLevel: Equatable {
        case normal
        case low
        case exhausted
    }

    /// The single next step the card offers; Pro in good standing gets none.
    enum Offer: Equatable {
        case upgrade
        /// `daysLeft` is nil when the current pace lasts until the reset.
        case lowQuota(daysLeft: Int?, canUpgrade: Bool)
        case exhausted(canUpgrade: Bool)
        case restore(endsOn: Date?)
        case fixPayment
    }

    /// Where the offer's button goes.
    enum Destination: Equatable {
        case plans
        case billingPortal
    }

    enum PeriodNote: Equatable {
        case resets(Date)
        case renews(Date)
        case ends(Date)
        case paymentFailed
    }

    let badge: Badge?
    let badgeTone: Tone
    let level: QuotaLevel
    let offer: Offer?
    /// The secondary link: the web plans page or the billing portal.
    let billingLink: Destination?
    let periodNote: PeriodNote?
    let forecast: AccountUsageForecast?

    static let lowThreshold = 0.2

    var offerDestination: Destination? {
        switch offer {
        case .upgrade, .lowQuota(_, true), .exhausted(true):
            .plans
        case .restore, .fixPayment:
            .billingPortal
        case .lowQuota, .exhausted, nil:
            nil
        }
    }

    var offerTone: Tone {
        switch offer {
        case .lowQuota: .warning
        case .exhausted, .fixPayment: .danger
        case .upgrade, .restore, nil: .accent
        }
    }

    static func make(
        subscription: BillingSubscriptionSnapshot,
        credits: CloudCreditSummary?,
        usagePeriodStart: String?,
        usagePeriodEnd: String?,
        now: Date = Date()
    ) -> AccountStatusPresentation {
        let quota = AccountUsageCreditPresentation(credits: credits)
        let level: QuotaLevel = if quota.isExhausted {
            .exhausted
        } else if let fraction = quota.remainingFraction, fraction < lowThreshold {
            .low
        } else {
            .normal
        }
        let paymentIssue = isPaymentIssue(subscription)
        let paid = subscription.hasPaidSubscription
        let canUpgrade = subscription.billingEnabled && !paid && !paymentIssue
        let forecast = AccountUsageForecast.make(
            credits: credits,
            periodStart: usagePeriodStart.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)),
            periodEnd: usagePeriodEnd.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)),
            now: now
        )

        let (badge, tone) = badge(for: subscription, quota: quota, level: level, paymentIssue: paymentIssue)

        let offer: Offer? = if paymentIssue {
            .fixPayment
        } else if paid, subscription.cancelAtPeriodEnd {
            .restore(endsOn: subscription.currentPeriodEnd.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)))
        } else if level == .exhausted {
            .exhausted(canUpgrade: canUpgrade)
        } else if level == .low {
            .lowQuota(daysLeft: forecast?.daysUntilExhausted, canUpgrade: canUpgrade)
        } else if canUpgrade {
            .upgrade
        } else {
            nil
        }

        let billingLink: Destination? = if paid || paymentIssue {
            .billingPortal
        } else if subscription.billingEnabled {
            .plans
        } else {
            nil
        }

        return AccountStatusPresentation(
            badge: badge,
            badgeTone: tone,
            level: level,
            offer: offer,
            billingLink: billingLink,
            periodNote: periodNote(for: subscription, paymentIssue: paymentIssue, usagePeriodEnd: usagePeriodEnd),
            forecast: forecast
        )
    }

    /// The Ask sidebar's badge: "Own models" replaces the plain plan label
    /// while Ask runs locally; quota and payment warnings still win, since
    /// dictation keeps using Cloud.
    func footerBadge(runsLocally: Bool) -> (badge: Badge?, tone: Tone) {
        guard runsLocally, badgeTone == .neutral || badgeTone == .accent else { return (badge, badgeTone) }
        return (.ownModels, .neutral)
    }

    static func isPaymentIssue(_ subscription: BillingSubscriptionSnapshot) -> Bool {
        let status = subscription.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["past_due", "unpaid", "incomplete"].contains(status ?? "")
    }

    /// Plan label for the badge: Free / Pro, else the server's name.
    static func planName(for subscription: BillingSubscriptionSnapshot) -> String? {
        let code = subscription.planCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if subscription.isFreePlan || code.lowercased() == "free" { return "Free" }
        if code.lowercased() == BillingPlan.defaultPlanCode { return "Pro" }
        if let name = subscription.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return code.isEmpty ? nil : code.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func badge(
        for subscription: BillingSubscriptionSnapshot,
        quota: AccountUsageCreditPresentation,
        level: QuotaLevel,
        paymentIssue: Bool
    ) -> (Badge?, Tone) {
        let plan = planName(for: subscription).map(Badge.plan)
        if paymentIssue { return (plan ?? .plan("Pro"), .danger) }
        switch level {
        case .exhausted:
            return (.exhausted, .danger)
        case .low:
            // Rounded down, but never "0%" while something is left.
            let percent = max(1, Int(((quota.remainingFraction ?? 0) * 100).rounded(.down)))
            return (.low(percent: percent), .warning)
        case .normal:
            // Without billing there are no plans to tell apart.
            guard subscription.billingEnabled || subscription.hasPaidSubscription else { return (nil, .neutral) }
            return (plan, subscription.hasPaidSubscription ? .accent : .neutral)
        }
    }

    private static func periodNote(
        for subscription: BillingSubscriptionSnapshot,
        paymentIssue: Bool,
        usagePeriodEnd: String?
    ) -> PeriodNote? {
        if paymentIssue { return .paymentFailed }
        if subscription.hasPaidSubscription,
           let end = subscription.currentPeriodEnd.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)) {
            return subscription.cancelAtPeriodEnd ? .ends(end) : .renews(end)
        }
        let end = usagePeriodEnd ?? subscription.currentPeriodEnd
        return end.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)).map(PeriodNote.resets)
    }
}

/// Where the period's quota is heading at the current pace.
struct AccountUsageForecast: Equatable {
    /// Share of the limit used so far, 0...1.
    let usedFraction: Double
    /// Share of the period that has passed, 0...1.
    let elapsedFraction: Double
    /// Share of the limit the period ends at if usage keeps this pace; nil too early to tell.
    let projectedFraction: Double?
    /// Whole days until the quota runs out at this pace; nil if it lasts the period.
    let daysUntilExhausted: Int?

    /// Too little of the period has passed to extrapolate below this.
    static let minimumElapsed: TimeInterval = 12 * 3600

    static func make(credits: CloudCreditSummary?, periodStart: Date?, periodEnd: Date?,
                     now: Date) -> AccountUsageForecast? {
        guard let credits, !credits.unlimited, credits.limit > 0,
              let periodStart, let periodEnd, periodEnd > periodStart else { return nil }
        let length = periodEnd.timeIntervalSince(periodStart)
        let elapsed = min(max(now.timeIntervalSince(periodStart), 0), length)
        let used = Double(max(0, min(credits.used, credits.limit)))
        let usedFraction = used / Double(credits.limit)
        let elapsedFraction = elapsed / length
        guard elapsed >= minimumElapsed else {
            return AccountUsageForecast(usedFraction: usedFraction, elapsedFraction: elapsedFraction,
                                        projectedFraction: nil, daysUntilExhausted: nil)
        }
        let projected = usedFraction / elapsedFraction
        let remaining = Double(max(0, credits.remaining))
        var days: Int?
        if used > 0, remaining > 0 {
            let secondsLeft = remaining / (used / elapsed)
            if secondsLeft < periodEnd.timeIntervalSince(now) {
                days = max(1, Int((secondsLeft / 86400).rounded(.up)))
            }
        }
        return AccountUsageForecast(usedFraction: usedFraction, elapsedFraction: elapsedFraction,
                                    projectedFraction: projected, daysUntilExhausted: days)
    }

    /// The pace runs past the limit before the period resets.
    var runsOut: Bool {
        (projectedFraction ?? 0) > 1
    }
}
