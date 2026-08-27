import SwiftUI

struct AccountUsageCreditPresentation: Equatable {
    enum Usage: Equatable {
        case unavailable
        case unlimited(used: Int)
        case limited(used: Int, limit: Int)
    }

    let credits: CloudCreditSummary?

    var usage: Usage {
        guard let credits else { return .unavailable }
        if credits.unlimited { return .unlimited(used: credits.used) }
        guard credits.limit >= 0 else { return .unavailable }
        return .limited(used: credits.used, limit: credits.limit)
    }

    var usageFraction: Double? {
        guard let credits, !credits.unlimited, credits.limit > 0 else { return nil }
        return max(0, Double(credits.used) / Double(credits.limit))
    }

    var progress: Double? {
        usageFraction.map { min($0, 1) }
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
            HStack(alignment: .center, spacing: StudioTheme.Spacing.mediumLarge) {
                quotaLabel
                Spacer(minLength: StudioTheme.Spacing.mediumLarge)
                Text(usedTotalDescription)
                    .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                    .foregroundStyle(presentation.usage == .unavailable
                        ? StudioTheme.textSecondary : StudioTheme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let progress = presentation.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioTheme.surfaceMuted)
                        Capsule()
                            .fill((presentation.usageFraction ?? 0) >= 1 ? StudioTheme.danger : StudioTheme.accent)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel(L("auth.account.usageQuota"))
                .accessibilityValue(usedTotalDescription + (percentageDescription.map { " · \($0)" } ?? ""))
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.large) {
                    usagePercentage
                    Spacer(minLength: StudioTheme.Spacing.large)
                    periodLabel
                }
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    usagePercentage
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
    private var usagePercentage: some View {
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

    private var usedTotalDescription: String {
        switch presentation.usage {
        case .unavailable:
            L("auth.account.usageQuotaUnavailable")
        case let .unlimited(used):
            L(
                "auth.account.usageQuotaUsedPair",
                AccountUsageDisplayFormatter.creditAmount(used), L("auth.account.usageQuotaUnlimited")
            )
        case let .limited(used, limit):
            L(
                "auth.account.usageQuotaUsedPair",
                AccountUsageDisplayFormatter.creditAmount(used), AccountUsageDisplayFormatter.creditAmount(limit)
            )
        }
    }

    private var percentageDescription: String? {
        guard let fraction = presentation.usageFraction else { return nil }
        return L("auth.account.usageQuotaUsedPercentage", AccountUsageDisplayFormatter.percentage(fraction * 100))
    }
}
