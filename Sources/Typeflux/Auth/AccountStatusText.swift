import Foundation

/// Localized wording for `AccountStatusPresentation`, shared by the Ask
/// account card and the account page.
enum AccountStatusText {
    struct OfferCopy: Equatable {
        let title: String
        let detail: String
        /// Nil when the offer only informs (e.g. a Pro user running low).
        let action: String?
    }

    static func badge(_ badge: AccountStatusPresentation.Badge) -> String {
        switch badge {
        case let .plan(name): name
        case let .low(percent): L("account.status.badgeLow", "\(percent)%")
        case .exhausted: L("account.status.badgeExhausted")
        case .ownModels: L("account.status.badgeOwnModels")
        }
    }

    /// "Nov 1" in the user's locale; the year only when it is not this year's.
    static func shortDate(_ date: Date, locale: Locale, timeZone: TimeZone = .current, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    static func period(_ note: AccountStatusPresentation.PeriodNote, locale: Locale,
                       timeZone: TimeZone = .current, now: Date = Date()) -> String {
        func day(_ date: Date) -> String { shortDate(date, locale: locale, timeZone: timeZone, now: now) }
        return switch note {
        case let .resets(date): L("account.status.resets", day(date))
        case let .renews(date): L("account.status.renews", day(date))
        case let .ends(date): L("account.status.ends", day(date))
        case .paymentFailed: L("account.status.paymentFailed")
        }
    }

    static func offer(_ offer: AccountStatusPresentation.Offer, locale: Locale,
                      timeZone: TimeZone = .current, now: Date = Date()) -> OfferCopy {
        switch offer {
        case .upgrade:
            return OfferCopy(title: L("account.offer.upgradeTitle"), detail: L("account.offer.upgradeDetail"),
                             action: L("account.offer.upgradeAction"))
        case let .lowQuota(daysLeft, canUpgrade):
            let detail = daysLeft.map { L("account.offer.lowDays", $0) } ?? L("account.offer.lowDetail")
            return OfferCopy(title: L("account.offer.lowTitle"), detail: detail,
                             action: canUpgrade ? L("account.offer.upgradeAction") : nil)
        case let .exhausted(canUpgrade):
            return OfferCopy(
                title: L("account.offer.exhaustedTitle"),
                detail: L(canUpgrade ? "account.offer.exhaustedUpgradeDetail" : "account.offer.exhaustedDetail"),
                action: canUpgrade ? L("account.offer.upgradeAction") : nil
            )
        case let .restore(endsOn):
            let title = endsOn.map {
                L("account.offer.restoreTitle", shortDate($0, locale: locale, timeZone: timeZone, now: now))
            } ?? L("account.offer.restoreTitleNoDate")
            return OfferCopy(title: title, detail: L("account.offer.restoreDetail"),
                             action: L("account.offer.restoreAction"))
        case .fixPayment:
            return OfferCopy(title: L("account.offer.fixPaymentTitle"), detail: L("account.offer.fixPaymentDetail"),
                             action: L("account.offer.fixPaymentAction"))
        }
    }

    static func provider(_ provider: String) -> String {
        switch provider {
        case "password": L("auth.account.providerEmail")
        case "google": L("auth.account.signedInWith", "Google")
        case "apple": L("auth.account.signedInWith", "Apple")
        case "github": L("auth.account.signedInWith", "GitHub")
        default: provider
        }
    }

    /// "1.42M / 2M" style pair for tight spaces, exact digits otherwise. Both
    /// sides use the limit's unit so they never mix ("9K / 60K", not "9,000 / 60K").
    static func quotaPair(remaining: Int, limit: Int, compact: Bool) -> String {
        guard compact else {
            return L("auth.account.usageQuotaRemainingPair", AccountUsageDisplayFormatter.creditAmount(remaining),
                     AccountUsageDisplayFormatter.creditAmount(limit))
        }
        let unit: CompactUnit? = if limit >= 1_000_000 {
            CompactUnit(divisor: 1_000_000, suffix: "M", digits: 2)
        } else if limit >= 10000 {
            CompactUnit(divisor: 1000, suffix: "K", digits: 1)
        } else {
            nil
        }
        let format: (Int) -> String = { value in
            guard let unit, value != 0 else { return AccountUsageDisplayFormatter.creditAmount(value) }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = unit.digits
            formatter.roundingMode = .down
            let scaled = Double(value) / unit.divisor
            return (formatter.string(from: NSNumber(value: scaled)) ?? "\(scaled)") + unit.suffix
        }
        return L("auth.account.usageQuotaRemainingPair", format(remaining), format(limit))
    }

    private struct CompactUnit {
        let divisor: Double
        let suffix: String
        let digits: Int
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded()))%"
    }
}
