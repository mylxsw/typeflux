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
        VStack(alignment: .leading, spacing: 0) {
            identityRow
                .padding(.horizontal, TypefluxSpacing.regular.value(for: .classic))
                .padding(.vertical, 10)

            divider

            if presentation.state != .signedOut {
                cardBody
                    .padding(.horizontal, TypefluxSpacing.regular.value(for: .classic))
                    .padding(.vertical, 10)

                divider
            }

            footer
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, TypefluxSpacing.small.value(for: .classic))
                .padding(.vertical, TypefluxSpacing.compact.value(for: .classic))
        }
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: .classic), style: .continuous)
                .fill(TypefluxColor.contentBackground.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: .classic), style: .continuous)
                .stroke(
                    presentation.needsAttention
                        ? TypefluxColor.warning.color.opacity(0.42)
                        : TypefluxColor.separator.color.opacity(0.72),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, -10)
    }

    private var identityRow: some View {
        HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
            identityControl

            Spacer(minLength: TypefluxSpacing.compact.value(for: .classic))

            if presentation.state != .loading {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(.callout, weight: .semibold))
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
        HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
            Image(
                systemName: presentation.usesFilledIdentityIcon
                    ? "person.circle.fill"
                    : "person.circle"
            )
            .font(.system(.body, weight: .medium))
            .foregroundStyle(identityColor)
            .accessibilityHidden(true)

            Text(identityTitle)
                .font(.system(.callout, weight: identityFontWeight))
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
            VStack(alignment: .leading, spacing: TypefluxSpacing.compact.value(for: .classic)) {
                Text(L("sidebar.accountCard.cloudAccount"))
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(TypefluxColor.label.color)

                Text(L("sidebar.accountCard.unavailable"))
                    .font(.system(.callout))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
        VStack(alignment: .leading, spacing: TypefluxSpacing.small.value(for: .classic)) {
            Text(L("sidebar.accountCard.cloudAccount"))
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(TypefluxColor.label.color)

            HStack(spacing: TypefluxSpacing.small.value(for: .classic)) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(TypefluxColor.controlBackground.color)
                        .frame(width: 108, height: 6)
                    Capsule()
                        .fill(TypefluxColor.controlBackground.color.opacity(0.82))
                        .frame(width: 84, height: 6)
                }

                Spacer(minLength: TypefluxSpacing.compact.value(for: .classic))

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
            VStack(alignment: .leading, spacing: TypefluxSpacing.compact.value(for: .classic)) {
                Text(planTitle)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(TypefluxColor.label.color)

                Text(L("sidebar.accountCard.billingAttention"))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(TypefluxColor.warning.color)
                    .lineLimit(1)

                Text(L("sidebar.accountCard.billingAttentionSubtitle"))
                    .font(.system(.callout))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .lineLimit(2)
            }
        } else {
            accountUsage
        }
    }

    private var accountUsage: some View {
        VStack(alignment: .leading, spacing: TypefluxSpacing.compact.value(for: .classic)) {
            Text(planTitle)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(TypefluxColor.label.color)
                .lineLimit(1)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: TypefluxSpacing.small.value(for: .classic)) {
                    quotaLabel
                    Spacer(minLength: TypefluxSpacing.small.value(for: .classic))
                    quotaValue
                }
                VStack(alignment: .leading, spacing: TypefluxSpacing.compact.value(for: .classic)) {
                    quotaLabel
                    quotaValue
                }
            }

            if let progress = presentation.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TypefluxColor.controlBackground.color)
                        Capsule()
                            .fill(presentation.creditPresentation.isExhausted ? TypefluxColor.danger
                                .color : TypefluxColor.accent.color)
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
            .font(.system(.callout))
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
                        ? TypefluxColor.danger.color : TypefluxColor.label.color)
                    .studioTooltip(remainingText(remaining: remaining, limit: limit, compact: false), yOffset: 18)
                    .accessibilityLabel(L(
                        "sidebar.accountCard.remaining",
                        remainingText(remaining: remaining, limit: limit, compact: false)
                    ))
            case .unavailable:
                Text("—")
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .help(L("sidebar.accountCard.quotaUnavailable"))
                    .accessibilityLabel(L("sidebar.accountCard.quotaUnavailable"))
            }
        }
        .font(.system(.body, weight: .semibold))
        .foregroundStyle(TypefluxColor.label.color)
        .monospacedDigit()
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(TypefluxColor.separator.color.opacity(0.42))
            .frame(height: 1)
            .padding(.horizontal, TypefluxSpacing.regular.value(for: .classic))
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
            ? TypefluxColor.secondaryLabel.color
            : TypefluxColor.label.color
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
        presentation.needsAttention ? TypefluxColor.warning.color : TypefluxColor.accent.color
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
