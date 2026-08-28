import AppKit
import SwiftUI

struct StudioSidebarAccountCard<Footer: View>: View {
    let presentation: SidebarAccountCardPresentation
    let action: () -> Void
    let identityAction: () -> Void
    let footer: Footer
    @State private var isHoveringIdentity = false

    init(
        presentation: SidebarAccountCardPresentation,
        action: @escaping () -> Void,
        identityAction: @escaping () -> Void,
        @ViewBuilder footer: () -> Footer
    ) {
        self.presentation = presentation
        self.action = action
        self.identityAction = identityAction
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.none) {
            identityRow
                .padding(.horizontal, StudioTheme.Spacing.smallMedium)
                .padding(.vertical, StudioTheme.Spacing.small)

            divider

            if presentation.state != .signedOut {
                cardBody
                    .padding(.horizontal, StudioTheme.Spacing.smallMedium)
                    .padding(.vertical, StudioTheme.Spacing.small)

                divider
            }

            footer
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, StudioTheme.Spacing.xSmall)
                .padding(.vertical, StudioTheme.Spacing.xxxSmall)
        }
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .stroke(
                    presentation.needsAttention
                        ? StudioTheme.warning.opacity(0.42)
                        : StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin
                )
        )
        .padding(.horizontal, -StudioTheme.Spacing.small)
    }

    private var identityRow: some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            identityControl

            Spacer(minLength: StudioTheme.Spacing.xxxSmall)

            if presentation.state != .loading {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                        .foregroundStyle(actionColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(StudioInteractiveButtonStyle())
                .layoutPriority(1)
                .accessibilityLabel(actionAccessibilityTitle)
                .accessibilityHint(actionTitle)
            }
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private var identityControl: some View {
        if isIdentityInteractive {
            Button(action: identityAction) {
                identityLabel
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .studioTooltip(L("sidebar.accountCard.viewAccountAccessibility"), yOffset: 24)
            .onHover { isHovering in
                guard isHovering != isHoveringIdentity else { return }
                isHoveringIdentity = isHovering
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHoveringIdentity {
                    NSCursor.pop()
                    isHoveringIdentity = false
                }
            }
            .accessibilityLabel(L("sidebar.accountCard.viewAccountAccessibility"))
        } else {
            identityLabel
        }
    }

    private var identityLabel: some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            Image(
                systemName: presentation.usesFilledIdentityIcon
                    ? "person.circle.fill"
                    : "person.circle"
            )
                .font(.system(size: StudioTheme.Typography.iconRegular, weight: .medium))
                .foregroundStyle(identityColor)
                .accessibilityHidden(true)

            Text(identityTitle)
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: identityFontWeight))
                .foregroundStyle(identityColor)
                .underline(isHoveringIdentity && isIdentityInteractive)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch presentation.state {
        case .signedOut:
            EmptyView()

        case .loading:
            loadingContent

        case .unavailable:
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(L("sidebar.accountCard.cloudAccount"))
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(L("sidebar.accountCard.unavailable"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .account:
            accountContent
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            Text(L("sidebar.accountCard.cloudAccount"))
                .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            HStack(spacing: StudioTheme.Spacing.xSmall) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                    Capsule()
                        .fill(StudioTheme.surfaceMuted)
                        .frame(width: 108, height: 6)
                    Capsule()
                        .fill(StudioTheme.surfaceMuted.opacity(0.82))
                        .frame(width: 84, height: 6)
                }

                Spacer(minLength: StudioTheme.Spacing.xxxSmall)

                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("sidebar.accountCard.loading"))
    }

    @ViewBuilder
    private var accountContent: some View {
        if presentation.needsAttention {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(planTitle)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(L("sidebar.accountCard.billingAttention"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.warning)
                    .lineLimit(1)

                Text(L("sidebar.accountCard.billingAttentionSubtitle"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2)
            }
        } else {
            accountUsage
        }
    }

    private var accountUsage: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
            Text(planTitle)
                .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.xSmall) {
                    quotaLabel
                    Spacer(minLength: StudioTheme.Spacing.xSmall)
                    quotaValue
                }
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                    quotaLabel
                    quotaValue
                }
            }

            if let progress = presentation.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioTheme.surfaceMuted)
                        Capsule()
                            .fill(presentation.creditPresentation.isExhausted ? StudioTheme.danger : StudioTheme.accent)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
    }

    private var quotaLabel: some View {
        Text(L("sidebar.accountCard.cloudCredits"))
            .font(.studioBody(StudioTheme.Typography.bodySmall))
            .foregroundStyle(StudioTheme.textSecondary)
            .fixedSize()
    }

    private var quotaValue: some View {
        Group {
            switch presentation.creditPresentation.balance {
            case .unlimited:
                Text(L("auth.account.usageQuotaUnlimited"))
            case let .limited(remaining, limit):
                Text(remainingText(remaining: remaining, limit: limit, compact: true))
                    .foregroundStyle(presentation.creditPresentation.isExhausted
                        ? StudioTheme.danger : StudioTheme.textPrimary)
                    .studioTooltip(remainingText(remaining: remaining, limit: limit, compact: false), yOffset: 18)
                    .accessibilityLabel(L(
                        "sidebar.accountCard.remaining",
                        remainingText(remaining: remaining, limit: limit, compact: false)
                    ))
            case .unavailable:
                Text("—")
                    .foregroundStyle(StudioTheme.textSecondary)
                    .help(L("sidebar.accountCard.quotaUnavailable"))
                    .accessibilityLabel(L("sidebar.accountCard.quotaUnavailable"))
            }
        }
        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
        .foregroundStyle(StudioTheme.textPrimary)
        .monospacedDigit()
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(StudioTheme.border.opacity(0.42))
            .frame(height: StudioTheme.BorderWidth.thin)
            .padding(.horizontal, StudioTheme.Spacing.smallMedium)
    }

    private var identityTitle: String {
        switch presentation.state {
        case .signedOut:
            L("sidebar.accountCard.guest")
        case .loading:
            L("sidebar.accountCard.account")
        case .unavailable, .account:
            presentation.displayName ?? L("sidebar.accountCard.account")
        }
    }

    private var identityColor: Color {
        presentation.state == .signedOut
            ? StudioTheme.textSecondary
            : StudioTheme.textPrimary
    }

    private var identityFontWeight: Font.Weight {
        presentation.state == .signedOut ? .medium : .semibold
    }

    private var isIdentityInteractive: Bool {
        presentation.state == .account || presentation.state == .unavailable
    }

    private var planTitle: String {
        presentation.planName ?? L("sidebar.accountCard.cloudAccount")
    }

    private var actionTitle: String {
        switch presentation.action {
        case .signIn:
            L("sidebar.accountCard.signIn")
        case .viewDetails:
            L("sidebar.accountCard.viewAccount")
        case .upgrade:
            L("sidebar.accountCard.upgrade")
        case .manageBilling:
            L("sidebar.accountCard.manage")
        case .resolveBilling:
            L("sidebar.accountCard.resolveBilling")
        }
    }

    private var actionColor: Color {
        presentation.needsAttention ? StudioTheme.warning : StudioTheme.accent
    }

    private var actionAccessibilityTitle: String {
        presentation.action == .viewDetails
            ? L("sidebar.accountCard.viewAccountAccessibility")
            : actionTitle
    }

    private func remainingText(remaining: Int, limit: Int, compact: Bool) -> String {
        let remainingAmount = compact
            ? AccountUsageDisplayFormatter.sidebarCreditAmount(remaining)
            : AccountUsageDisplayFormatter.count(Int64(remaining))
        let limitAmount = compact
            ? AccountUsageDisplayFormatter.sidebarCreditAmount(limit)
            : AccountUsageDisplayFormatter.count(Int64(limit))
        return String(format: L("sidebar.accountCard.usagePair"), remainingAmount, limitAmount)
    }
}
