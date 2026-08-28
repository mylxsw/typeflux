import SwiftUI

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

    var isExhausted: Bool {
        guard case let .limited(remaining, limit) = balance else { return false }
        return limit > 0 && remaining == 0
    }
}

struct AccountUsageCreditProgressView: View {
    let credits: CloudCreditSummary?
    var isFreeAllowance = false
    var periodDescription: String?
    @State private var showsQuotaExplanation = false

    private var presentation: AccountUsageCreditPresentation {
        AccountUsageCreditPresentation(credits: credits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.mediumLarge) {
                quotaLabel
                Spacer(minLength: StudioTheme.Spacing.mediumLarge)
                Text(remainingTotalDescription)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(presentation.balance == .unavailable
                        ? StudioTheme.textSecondary
                        : (presentation.isExhausted ? StudioTheme.danger : StudioTheme.textPrimary))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(presentation.balance == .unavailable
                        ? remainingTotalDescription
                        : L("auth.account.usageQuotaRemainingPercentage", remainingTotalDescription))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let progress = presentation.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioTheme.surfaceMuted)
                        Capsule()
                            .fill(presentation.isExhausted ? StudioTheme.danger : StudioTheme.accent)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel(L("auth.account.usageQuota"))
                .accessibilityValue(remainingTotalDescription + (percentageDescription.map { " · \($0)" } ?? ""))
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.large) {
                    remainingPercentage
                    Spacer(minLength: StudioTheme.Spacing.large)
                    periodLabel
                }
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    remainingPercentage
                    periodLabel
                }
            }
            .font(.studioBody(StudioTheme.Typography.bodySmall))
            .foregroundStyle(StudioTheme.textSecondary)
        }
    }

    private var quotaLabel: some View {
        HStack(spacing: StudioTheme.Spacing.xxSmall) {
            Text(L(isFreeAllowance ? "auth.account.usageFreeQuota" : "auth.account.usageQuotaCurrentPeriod"))
                .font(.studioBody(StudioTheme.Typography.body))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Button {
                showsQuotaExplanation.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: StudioTheme.Typography.iconSmall))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("auth.account.usageQuotaExplanation"))
            .accessibilityLabel(L("auth.account.usageQuotaExplanationTitle"))
            .popover(isPresented: $showsQuotaExplanation) {
                Text(L("auth.account.usageQuotaExplanation"))
                    .font(.studioBody(StudioTheme.Typography.body))
                    .padding(StudioTheme.Spacing.mediumLarge)
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(StudioTheme.textSecondary)
    }

    @ViewBuilder
    private var remainingPercentage: some View {
        if let percentageDescription {
            Text(percentageDescription)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var periodLabel: some View {
        if let periodDescription {
            Text(periodDescription)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remainingTotalDescription: String {
        switch presentation.balance {
        case .unavailable:
            L("auth.account.usageQuotaUnavailable")
        case .unlimited:
            L("auth.account.usageQuotaUnlimited")
        case let .limited(remaining, limit):
            L(
                "auth.account.usageQuotaRemainingPair",
                AccountUsageDisplayFormatter.creditAmount(remaining), AccountUsageDisplayFormatter.creditAmount(limit)
            )
        }
    }

    private var percentageDescription: String? {
        guard let fraction = presentation.remainingFraction else { return nil }
        return L("auth.account.usageQuotaRemainingPercentage", AccountUsageDisplayFormatter.percentage(fraction * 100))
    }
}
