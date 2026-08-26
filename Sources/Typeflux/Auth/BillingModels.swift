import Foundation

struct BillingSubscriptionSnapshot: Decodable, Equatable {
    let billingEnabled: Bool
    let planCode: String?
    let planName: String?
    let status: String?
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool
    let entitled: Bool
    let active: Bool
    let paid: Bool
    let periodSource: String?

    enum CodingKeys: String, CodingKey {
        case active
        case paid
        case billingEnabled = "billing_enabled"
        case planCode = "plan_code"
        case planName = "plan_name"
        case status
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case entitled
        case periodSource = "period_source"
        case subscription
        case entitlement
    }

    enum EntitlementCodingKeys: String, CodingKey {
        case entitled
    }

    init(
        planCode: String?,
        status: String?,
        currentPeriodStart: String?,
        currentPeriodEnd: String?,
        cancelAtPeriodEnd: Bool,
        entitled: Bool,
        planName: String? = nil,
        active: Bool? = nil,
        paid: Bool? = nil,
        periodSource: String? = nil,
        billingEnabled: Bool = false
    ) {
        self.billingEnabled = billingEnabled
        self.planCode = planCode
        self.planName = planName
        self.status = status
        self.currentPeriodStart = currentPeriodStart
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.entitled = entitled
        self.active = active ?? entitled
        self.paid = paid ?? Self.defaultPaid(planCode: planCode, status: status)
        self.periodSource = periodSource
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let source = (try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .subscription)) ?? root
        let entitlement = try? root.nestedContainer(keyedBy: EntitlementCodingKeys.self, forKey: .entitlement)

        let planCode = try source.decodeIfPresent(String.self, forKey: .planCode)
        let status = try source.decodeIfPresent(String.self, forKey: .status)
        let active = try source.decodeIfPresent(Bool.self, forKey: .active)
        let entitled = try entitlement?.decodeIfPresent(Bool.self, forKey: .entitled)
            ?? source.decodeIfPresent(Bool.self, forKey: .entitled)
            ?? root.decodeIfPresent(Bool.self, forKey: .entitled)
            ?? active
            ?? Self.defaultEntitlement(
                for: status,
                periodEnd: source.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
            )

        try self.init(
            planCode: planCode,
            status: status,
            currentPeriodStart: source.decodeIfPresent(String.self, forKey: .currentPeriodStart),
            currentPeriodEnd: source.decodeIfPresent(String.self, forKey: .currentPeriodEnd),
            cancelAtPeriodEnd: source.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false,
            entitled: entitled,
            planName: source.decodeIfPresent(String.self, forKey: .planName),
            active: active,
            paid: source.decodeIfPresent(Bool.self, forKey: .paid),
            periodSource: source.decodeIfPresent(String.self, forKey: .periodSource),
            billingEnabled: root.decodeIfPresent(Bool.self, forKey: .billingEnabled)
                ?? source.decodeIfPresent(Bool.self, forKey: .billingEnabled)
                ?? false
        )
    }

    var hasSubscription: Bool {
        guard let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var shouldShowSubscriptionDetails: Bool {
        billingEnabled
    }

    var treatsCreditsAsFreeAllowance: Bool {
        !billingEnabled
    }

    func disablingBilling() -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: planCode,
            status: status,
            currentPeriodStart: currentPeriodStart,
            currentPeriodEnd: currentPeriodEnd,
            cancelAtPeriodEnd: cancelAtPeriodEnd,
            entitled: entitled,
            planName: planName,
            active: active,
            paid: paid,
            periodSource: periodSource,
            billingEnabled: false
        )
    }

    var hasPaidSubscription: Bool {
        paid && hasSubscription && !isFreePlan
    }

    var isFreePlan: Bool {
        let normalizedPlan = planCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSource = periodSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !paid && (normalizedPlan == "free" || normalizedStatus == "free" || normalizedSource == "free")
    }

    static var none: BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: nil,
            status: nil,
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: false,
            active: false,
            paid: false,
            billingEnabled: false
        )
    }

    private static func defaultEntitlement(for status: String?, periodEnd: String?) -> Bool {
        guard let status else { return false }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "active" || normalized == "trialing" || normalized == "free" else {
            return false
        }
        guard let periodEnd, let endDate = ISO8601DateFormatter.typefluxBillingDate(from: periodEnd) else {
            return true
        }
        return endDate > Date()
    }

    private static func defaultPaid(planCode: String?, status: String?) -> Bool {
        guard let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalizedPlan = planCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedPlan != "free" && normalizedStatus != "free"
    }
}

struct BillingCheckoutSession: Decodable, Equatable {
    let sessionID: String?
    let url: URL

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case url
    }
}

struct BillingPortalSession: Decodable, Equatable {
    let url: URL
}

struct BillingPageTokenResponse: Decodable, Equatable {
    let token: String
    let plansURL: URL

    enum CodingKeys: String, CodingKey {
        case token
        case plansURL = "plans_url"
    }
}

struct BillingCheckoutSessionRequest: Encodable {
    let planCode: String

    enum CodingKeys: String, CodingKey {
        case planCode = "plan_code"
    }
}

enum BillingPlan {
    static let defaultPlanCode = "pro"
}

struct AccountSubscriptionPresentation: Equatable {
    enum BillingAction: Equatable {
        case subscribe
        case manageBilling
    }

    enum TextValue: Equatable {
        case localized(String)
        case literal(String)
    }

    enum PeriodValue: Equatable {
        case unavailable
        case renewsOn(String)
        case endsOn(String)
        case cycle(start: String?, end: String)
    }

    let subtitleKey: String
    let plan: TextValue
    let status: TextValue
    let periodLabelKey: String
    let period: PeriodValue
    let billingAction: BillingAction
    let showsSubscriptionSyncAction: Bool

    static func make(from snapshot: BillingSubscriptionSnapshot) -> AccountSubscriptionPresentation {
        AccountSubscriptionPresentation(
            subtitleKey: subtitleKey(for: snapshot),
            plan: planValue(for: snapshot),
            status: statusValue(for: snapshot),
            periodLabelKey: periodLabelKey(for: snapshot),
            period: periodValue(for: snapshot),
            billingAction: snapshot.hasPaidSubscription ? .manageBilling : .subscribe,
            showsSubscriptionSyncAction: snapshot.billingEnabled && !snapshot.hasPaidSubscription
        )
    }

    private static func subtitleKey(for snapshot: BillingSubscriptionSnapshot) -> String {
        if snapshot.isFreePlan {
            return "auth.account.subscriptionFreeHint"
        }
        if snapshot.entitled {
            return "auth.account.subscriptionActiveHint"
        }
        if snapshot.hasSubscription {
            return "auth.account.subscriptionInactiveHint"
        }
        return "auth.account.subscriptionRequiredHint"
    }

    private static func periodLabelKey(for snapshot: BillingSubscriptionSnapshot) -> String {
        snapshot.isFreePlan ? "auth.account.subscriptionBillingCycle" : "auth.account.subscriptionPeriod"
    }

    private static func planValue(for snapshot: BillingSubscriptionSnapshot) -> TextValue {
        guard let planCode = snapshot.planCode, !planCode.isEmpty else {
            return .localized("auth.account.subscriptionNoPlan")
        }
        if planCode == "free" {
            return .localized("auth.account.subscriptionFreePlan")
        }
        if planCode == BillingPlan.defaultPlanCode {
            return .localized("auth.account.subscriptionDefaultPlan")
        }
        if let planName = snapshot.planName, !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .literal(planName)
        }
        return .literal(planCode.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private static func statusValue(for snapshot: BillingSubscriptionSnapshot) -> TextValue {
        guard let status = snapshot.status, !status.isEmpty else {
            return .localized("auth.account.subscriptionStatusNone")
        }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "free":
            return .localized("auth.account.subscriptionStatusAvailable")
        case "active":
            return .localized("auth.account.subscriptionStatusActive")
        case "trialing":
            return .localized("auth.account.subscriptionStatusTrialing")
        case "past_due":
            return .localized("auth.account.subscriptionStatusPastDue")
        case "canceled", "cancelled":
            return .localized("auth.account.subscriptionStatusCanceled")
        case "unpaid":
            return .localized("auth.account.subscriptionStatusUnpaid")
        default:
            return .literal(status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    private static func periodValue(for snapshot: BillingSubscriptionSnapshot) -> PeriodValue {
        guard let periodEnd = snapshot.currentPeriodEnd else {
            return .unavailable
        }
        if snapshot.isFreePlan {
            return .cycle(start: snapshot.currentPeriodStart, end: periodEnd)
        }
        if snapshot.cancelAtPeriodEnd {
            return .endsOn(periodEnd)
        }
        return .renewsOn(periodEnd)
    }
}

extension ISO8601DateFormatter {
    static func typefluxBillingDate(from string: String) -> Date? {
        typefluxBilling.date(from: string) ?? typefluxBillingFallback.date(from: string)
    }

    static let typefluxBilling: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let typefluxBillingFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
