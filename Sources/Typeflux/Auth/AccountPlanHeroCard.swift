import AppKit
import SwiftUI

/// The account page's plan card: plan and status, what is left this period,
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
        StudioCard {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.xxLarge) {
                VStack(alignment: .leading, spacing: 0) {
                    planLine(status)
                    switch status.periodNote {
                    case .ends, nil:
                        EmptyView()
                    case let note?:
                        Text(AccountStatusText.period(note, locale: localization.locale))
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(note == .paymentFailed ? StudioTheme.danger : StudioTheme.textSecondary)
                            .padding(.top, 4)
                    }
                    quota(status)
                    messages
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsBilling {
                    Rectangle().fill(StudioTheme.border).frame(width: 1).padding(.vertical, 4)
                    actions(status).frame(width: 200)
                }
            }
        }
    }

    private func planLine(_ status: AccountStatusPresentation) -> some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            Text(showsBilling
                ? "\(L("sidebar.accountCard.cloudAccount")) · \(text(subscription.plan))"
                : L("sidebar.accountCard.cloudAccount"))
                .font(.studioBody(StudioTheme.Typography.subsectionTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            if showsBilling {
                HStack(spacing: 5) {
                    Circle().fill(statusColor(status)).frame(width: 7, height: 7)
                    Text(text(subscription.status))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(statusColor(status))
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: StudioTheme.Spacing.xSmall)
            AccountRefreshIconButton(
                helpText: L("auth.account.refreshOverview"),
                isDisabled: authState.isLoadingSubscription || authState.isLoadingUsage
                    || authState.isSyncingSubscription || isOpeningBilling,
                isLoading: authState.isLoadingSubscription || authState.isLoadingUsage,
                action: onRefresh
            )
        }
    }

    private func statusColor(_ status: AccountStatusPresentation) -> Color {
        if AccountStatusPresentation.isPaymentIssue(authState.subscription) { return StudioTheme.danger }
        if authState.subscription.cancelAtPeriodEnd { return StudioTheme.warning }
        return authState.subscription.entitled ? StudioTheme.success : StudioTheme.textSecondary
    }

    @ViewBuilder
    private func quota(_ status: AccountStatusPresentation) -> some View {
        let credits = AccountUsageCreditPresentation(credits: authState.usageCredits)
        switch credits.balance {
        case let .limited(remaining, limit):
            if let summary = credits.credits {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AccountUsageDisplayFormatter.creditAmount(summary.spendableRemaining))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(status.level == .exhausted ? StudioTheme.danger : StudioTheme.textPrimary)
                            .monospacedDigit()
                        Text(L("account.page.remaining"))
                            .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Text(L("account.page.periodUsage",
                           AccountUsageDisplayFormatter.creditAmount(summary.used),
                           AccountStatusText.quotaPair(remaining: remaining, limit: limit, compact: false)))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                    if let range = periodRange {
                        Text(range)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                .padding(.top, StudioTheme.Spacing.medium)
                addon(credits)
                if status.level == .exhausted {
                    Text(L("account.offer.exhaustedDetail"))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.top, 10)
                }
            }
        case .unlimited:
            Text(L("auth.account.usageQuotaUnlimited"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(.top, StudioTheme.Spacing.medium)
            addon(credits)
        case .unavailable:
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                if authState.isLoadingUsage { ProgressView().controlSize(.small) }
                Text(L(authState.isLoadingUsage ? "account.card.loading" : "account.card.quotaUnavailable"))
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.top, StudioTheme.Spacing.medium)
        }
    }

    @ViewBuilder
    private func addon(_ credits: AccountUsageCreditPresentation) -> some View {
        if let addon = credits.addon() {
            AccountAddonCreditRow(addon: addon, compact: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AskAccountTone.chip))
                .padding(.top, 12)
        }
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
    private var messages: some View {
        ForEach(Array([errorMessage, authState.usageError].compactMap { $0 }.enumerated()), id: \.offset) { item in
            Text(item.element)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private func actions(_ status: AccountStatusPresentation) -> some View {
        let paid = authState.subscription.hasPaidSubscription
            || AccountStatusPresentation.isPaymentIssue(authState.subscription)
        let primary: (title: String, destination: AccountStatusPresentation.Destination)
        if authState.subscription.isPrepaidMembership {
            primary = (L("auth.account.renewMembership"), .plans)
        } else {
            primary = switch status.offer {
            case .fixPayment: (L("account.page.fixPayment"), .billingPortal)
            case .restore: (L("account.offer.restoreAction"), .billingPortal)
            default: paid ? (L("account.card.manage"), .billingPortal) : (L("account.offer.upgradeTitle"), .plans)
            }
        }
        return VStack(spacing: StudioTheme.Spacing.xSmall) {
            StudioButton(title: primary.title, systemImage: nil, variant: .primary,
                         isDisabled: isOpeningBilling || authState.isSyncingSubscription,
                         isLoading: isOpeningBilling) { onOpenBilling(primary.destination) }
                .frame(maxWidth: .infinity)
            if paid && !authState.subscription.isPrepaidMembership {
                // Fixing a payment or resuming happen in the same portal.
                Text(L("account.card.manageHint"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            if subscription.showsSubscriptionSyncAction {
                HStack(spacing: 4) {
                    Text(L("account.page.paidNotActive"))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Button(action: onSync) {
                        if authState.isSyncingSubscription {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(L("account.page.refreshStatus")).foregroundStyle(StudioTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(authState.isSyncingSubscription || authState.isLoadingSubscription || isOpeningBilling)
                }
                .font(.studioBody(StudioTheme.Typography.caption))
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
