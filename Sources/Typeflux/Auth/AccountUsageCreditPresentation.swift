import Foundation

struct AccountUsageCreditPresentation: Equatable {
    enum Balance: Equatable {
        case unavailable
        case unlimited
        case limited(remaining: Int, limit: Int)
    }

    let credits: CloudCreditSummary?

    var balance: Balance {
        guard let credits else { return .unavailable }
        if credits.unlimited { return .unlimited }
        guard credits.limit >= 0 else { return .unavailable }
        return .limited(remaining: max(0, credits.remaining), limit: credits.limit)
    }

    var remainingFraction: Double? {
        guard case let .limited(remaining, limit) = balance, limit > 0 else { return nil }
        return Double(remaining) / Double(limit)
    }

    var progress: Double? {
        remainingFraction.map { min($0, 1) }
    }

    /// The month is used up and no add-on credits are left to continue with.
    var isExhausted: Bool {
        guard case let .limited(remaining, limit) = balance else { return false }
        return limit > 0 && remaining == 0 && addonRemaining == 0
    }

    var addonRemaining: Int { credits?.addonRemaining ?? 0 }

    /// Purchased credits and the purchase that expires first.
    struct Addon: Equatable {
        let remaining: Int
        let expiringCredits: Int?
        let expiresAt: Date?
        /// The next expiry is within `expiryWarningDays`.
        let expiresSoon: Bool
    }

    static let expiryWarningDays = 30

    /// Nil when the account has no add-on credits and none are waiting to expire.
    func addon(now: Date = Date()) -> Addon? {
        guard let addon = credits?.addon else { return nil }
        let expiry = addon.nextExpiry.flatMap { value in value.date.map { (credits: value.credits, date: $0) } }
        let remaining = max(0, addon.remaining)
        guard remaining > 0 || expiry != nil else { return nil }
        let warningEnd = now.addingTimeInterval(TimeInterval(Self.expiryWarningDays) * 86400)
        return Addon(
            remaining: remaining,
            expiringCredits: expiry.map { max(0, $0.credits) },
            expiresAt: expiry?.date,
            expiresSoon: remaining > 0 && expiry.map { $0.date > now && $0.date <= warningEnd } == true
        )
    }
}
