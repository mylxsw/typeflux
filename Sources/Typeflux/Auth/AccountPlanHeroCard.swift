import AppKit
import SwiftUI

/// The account page's plan section: plan and status, what is left this period,
/// how the period is going, and the one billing action that fits the state.
struct AccountPlanHeroCard: View {
    @ObservedObject var authState: AuthState
    let isOpeningBilling: Bool
    let errorMessage: String?
    let onOpenBilling: (AccountStatusPresentation.Destination) -> Void
    let onSync: () -> Void
    let onRefresh: () -> Void
    @ObservedObject private var localization = AppLocalization.shared

    private var status: AccountStatusPresentation {
        AccountStatusPresentation.make(subscription: authState.subscription, credits: authState.usageCredits,
                                       usagePeriodStart: authState.usagePeriodStart,
                                       usagePeriodEnd: authState.usagePeriodEnd)
    }

    private var subscription: AccountSubscriptionPresentation {
        AccountSubscriptionPresentation.make(from: authState.subscription)
    }

    private var showsBilling: Bool {
        authState.subscription.shouldShowSubscriptionDetails
    }

    var body: some View {
        let status = status
        TypefluxFormSection(L("sidebar.accountCard.cloudAccount")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    planLine()
                    if let note = status.periodNote {
                        Text(AccountStatusText.period(note, locale: localization.locale))
                            .font(.callout)
                            .foregroundStyle(note == .paymentFailed
                                ? TypefluxColor.danger.color : TypefluxColor.secondaryLabel.color)
                            .padding(.top, 4)
                    }
                    quota(status)
                    messages
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsBilling {
                    actions(status)
                }
            }
        }
    }

    private func planLine() -> some View {
        HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
            Text(showsBilling
                ? "\(L("sidebar.accountCard.cloudAccount")) · \(text(subscription.plan))"
                : L("sidebar.accountCard.cloudAccount"))
                .font(.headline.weight(.bold))
                .foregroundStyle(TypefluxColor.label.color)
            if showsBilling {
                TypefluxStatus(text(subscription.status), tone: statusTone)
            }
            Spacer(minLength: TypefluxSpacing.small.value(for: .classic))
            AccountRefreshIconButton(
                helpText: L("auth.account.refreshOverview"),
                isDisabled: authState.isLoadingSubscription || authState.isLoadingUsage
                    || authState.isSyncingSubscription || isOpeningBilling,
                isLoading: authState.isLoadingSubscription || authState.isLoadingUsage,
                action: onRefresh
            )
        }
    }

    private var statusTone: TypefluxTone {
        if AccountStatusPresentation.isPaymentIssue(authState.subscription) { return .danger }
        if authState.subscription.cancelAtPeriodEnd { return .warning }
        return authState.subscription.entitled ? .success : .neutral
    }

    @ViewBuilder
    private func quota(_ status: AccountStatusPresentation) -> some View {
        let credits = AccountUsageCreditPresentation(credits: authState.usageCredits)
        switch credits.balance {
        case let .limited(remaining, limit):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AccountStatusText.quotaPair(remaining: remaining, limit: limit, compact: false))
                        .font(.body.weight(.bold))
                        .foregroundStyle(status.level == .exhausted
                            ? TypefluxColor.danger.color : TypefluxColor.label.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(L(authState.subscription.treatsCreditsAsFreeAllowance
                            ? "auth.account.usageFreeQuota" : "account.page.remaining"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .lineLimit(1)
                }
                .padding(.top, 14)
                TypefluxProgress(L("auth.account.usageQuota"), value: credits.progress ?? 0)
                    .padding(.top, 10)
                    .accessibilityElement()
                    .accessibilityLabel(L("auth.account.usageQuota"))
                    .accessibilityValue(L("auth.account.usageQuotaRemainingPercentage",
                                          AccountStatusText.percent(credits.remainingFraction ?? 0)))
                periodProgress(status)
                addon(credits)
                forecast(status)
            }
        case .unlimited:
            Text(L("auth.account.usageQuotaUnlimited"))
                .font(.body.weight(.bold))
                .foregroundStyle(TypefluxColor.label.color)
                .padding(.top, 14)
            addon(credits)
        case .unavailable:
            HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
                if authState.isLoadingUsage { TypefluxProgress(L("account.card.loading")).labelsHidden() }
                Text(L(authState.isLoadingUsage ? "account.card.loading" : "account.card.quotaUnavailable"))
                    .font(.body)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func addon(_ credits: AccountUsageCreditPresentation) -> some View {
        if let addon = credits.addon() {
            AccountAddonCreditRow(addon: addon, compact: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func periodProgress(_ status: AccountStatusPresentation) -> some View {
        HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
            if let forecast = status.forecast {
                Text(L("account.page.usedVsElapsed", AccountStatusText.percent(forecast.usedFraction),
                       AccountStatusText.percent(forecast.elapsedFraction)))
                    .monospacedDigit()
            }
            Spacer(minLength: TypefluxSpacing.small.value(for: .classic))
            if let range = periodRange {
                Text(range)
            }
        }
        .font(.subheadline)
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .padding(.top, 6)
    }

    private var periodRange: String? {
        guard let start = authState.usagePeriodStart.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)),
              let end = authState.usagePeriodEnd.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:))
        else { return nil }
        let locale = localization.locale
        let from = AccountStatusText.shortDate(start, locale: locale)
        return from + " – " + AccountStatusText.shortDate(end, locale: locale)
    }

    @ViewBuilder
    private func forecast(_ status: AccountStatusPresentation) -> some View {
        if status.level == .exhausted {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(TypefluxColor.danger.color)
                Text(L("account.offer.exhaustedDetail"))
                    .font(.callout)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            .padding(.top, 10)
        } else if let forecast = status.forecast {
            let runsOut = forecast.daysUntilExhausted != nil
            HStack(spacing: 6) {
                Image(systemName: runsOut ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(runsOut ? TypefluxColor.warning.color : TypefluxColor.tertiaryLabel.color)
                Text(forecastText(forecast))
                    .font(.callout)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        }
    }

    private func forecastText(_ forecast: AccountUsageForecast) -> String {
        if let days = forecast.daysUntilExhausted {
            return L("account.page.forecastRunsOut", days)
        }
        if let projected = forecast.projectedFraction {
            return L("account.page.forecastEnough", AccountStatusText.percent(min(projected, 1)))
        }
        return L("account.page.forecastEarly")
    }

    @ViewBuilder
    private var messages: some View {
        ForEach(Array([errorMessage, authState.usageError].compactMap { $0 }.enumerated()), id: \.offset) { item in
            Text(item.element)
                .font(.callout)
                .foregroundStyle(TypefluxColor.danger.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private func actions(_ status: AccountStatusPresentation) -> some View {
        let paid = authState.subscription.hasPaidSubscription
            || AccountStatusPresentation.isPaymentIssue(authState.subscription)
        let primary: (title: String, destination: AccountStatusPresentation.Destination) = switch status.offer {
        case .fixPayment: (L("account.page.fixPayment"), .billingPortal)
        case .restore: (L("account.offer.restoreAction"), .billingPortal)
        default: paid ? (L("account.card.manage"), .billingPortal) : (L("account.offer.upgradeTitle"), .plans)
        }
        return VStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
            TypefluxButton(kind: .primary) { onOpenBilling(primary.destination) } label: {
                HStack {
                    if isOpeningBilling { TypefluxProgress(primary.title).labelsHidden().accessibilityHidden(true) }
                    Text(primary.title)
                }
            }
            .accessibilityLabel(primary.title)
            .disabled(isOpeningBilling || authState.isSyncingSubscription)
            if paid {
                // Fixing a payment or resuming happen in the same portal.
                Text(L("account.card.manageHint"))
                    .font(.subheadline)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            if subscription.showsSubscriptionSyncAction {
                HStack(spacing: 4) {
                    Text(L("account.page.paidNotActive"))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    TypefluxButton(L("account.page.refreshStatus"), kind: .link, action: onSync)
                        .disabled(authState.isSyncingSubscription
                            || authState.isLoadingSubscription || isOpeningBilling)
                }
                .font(.subheadline)
                .padding(.top, 2)
            }
        }
    }

    private func text(_ value: AccountSubscriptionPresentation.TextValue) -> String {
        switch value {
        case let .localized(key): L(key)
        case let .literal(text): text
        }
    }
}
