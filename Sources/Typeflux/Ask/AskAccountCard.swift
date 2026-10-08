import AppKit
import SwiftUI

/// The glass card above the footer name: who is signed in, what is left this
/// period, what was used, the one next step, and links to the account page and
/// billing.
struct AskAccountCard: View {
    static let width: CGFloat = 300

    @ObservedObject var auth: AuthState
    let onOpenAccount: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var openingBilling = false
    @State private var billingError: String?

    private var presentation: AccountStatusPresentation {
        AccountStatusPresentation.make(subscription: auth.subscription, credits: auth.usageCredits,
                                       usagePeriodStart: auth.usagePeriodStart, usagePeriodEnd: auth.usagePeriodEnd)
    }

    var body: some View {
        let presentation = presentation
        VStack(alignment: .leading, spacing: 6) {
            header(presentation)
            quota(presentation)
            tiles
            if let offer = presentation.offer {
                offerRow(offer, presentation: presentation)
            }
            if let billingError {
                Text(billingError)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
            links(presentation)
        }
        .padding(6)
        .frame(width: Self.width)
        .task { await auth.refreshAccountSummary() }
    }

    private func header(_ presentation: AccountStatusPresentation) -> some View {
        // The badge rides on the name line so the email keeps the full width.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(auth.userProfile?.resolvedDisplayName ?? L("sidebar.appName"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = presentation.badge {
                    AskAccountBadge(text: AccountStatusText.badge(badge), tone: presentation.badgeTone)
                }
            }
            if let profile = auth.userProfile {
                Text(verbatim: "\(profile.email) · \(AccountStatusText.provider(profile.provider))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func quota(_ presentation: AccountStatusPresentation) -> some View {
        let credits = AccountUsageCreditPresentation(credits: auth.usageCredits)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("auth.account.usageQuotaCurrentPeriod"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 8)
                quotaAmount(credits.balance)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .monospacedDigit()
            }
            if let progress = credits.progress {
                AskAccountProgressBar(progress: progress, color: AskAccountTone.bar(presentation.level))
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            } else {
                Spacer().frame(height: 6)
            }
            HStack {
                if let fraction = credits.remainingFraction {
                    Text(L("auth.account.usageQuotaRemainingPercentage", AccountStatusText.percent(fraction)))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if let note = presentation.periodNote {
                    Text(AccountStatusText.period(note, locale: localization.locale))
                        .foregroundStyle(note == .paymentFailed ? StudioTheme.danger : StudioTheme.textTertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.textTertiary)
            if let addon = credits.addon() {
                Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.vertical, 8)
                AccountAddonCreditRow(addon: addon)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AskAccountTone.chip))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func quotaAmount(_ balance: AccountUsageCreditPresentation.Balance) -> some View {
        switch balance {
        case let .limited(remaining, limit):
            Text(AccountStatusText.quotaPair(remaining: remaining, limit: limit, compact: true))
        case .unlimited:
            Text(L("auth.account.usageQuotaUnlimited"))
        case .unavailable:
            if auth.isLoadingUsage {
                ProgressView().controlSize(.mini)
            } else {
                Text(L("account.card.quotaUnavailable")).foregroundStyle(StudioTheme.textTertiary)
            }
        }
    }

    private var tiles: some View {
        let stats = auth.usageStats
        return HStack(spacing: 4) {
            tile(L("account.card.times", AccountUsageDisplayFormatter.count(stats.asrCount)), L("account.card.voice"))
            tile(AccountUsageDisplayFormatter.audioDuration(stats.asrAudioDurationMs), L("account.card.recording"))
            tile(L("account.card.times", AccountUsageDisplayFormatter.count(stats.chatCount)),
                 L("account.card.aiRequests"))
        }
        .padding(.horizontal, 4)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AskAccountTone.chip))
    }

    private func offerRow(_ offer: AccountStatusPresentation.Offer,
                          presentation: AccountStatusPresentation) -> some View {
        let copy = AccountStatusText.offer(offer, locale: localization.locale)
        let tone = presentation.offerTone
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(copy.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = copy.action, let destination = presentation.offerDestination {
                Button { openBilling(destination) } label: {
                    Group {
                        if openingBilling {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Text(action)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(tone == .accent ? StudioTheme.accent : AskAccountTone.foreground(tone)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(openingBilling)
                .fixedSize()
            }
        }
        .padding(10)
        .background(offerBackground(tone))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func offerBackground(_ tone: AccountStatusPresentation.Tone) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if tone == .accent {
            shape.fill(LinearGradient(colors: [StudioTheme.accent.opacity(0.16), Color.purple.opacity(0.13)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.strokeBorder(StudioTheme.accent.opacity(0.25)))
        } else {
            shape.fill(AskAccountTone.fill(tone))
        }
    }

    private func links(_ presentation: AccountStatusPresentation) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 6).padding(.bottom, 4)
            AskAccountLinkRow(symbol: "person.crop.circle", title: L("account.card.profile"),
                              trailing: L("account.card.profileHint"), external: false, action: onOpenAccount)
            switch presentation.billingLink {
            case .plans:
                AskAccountLinkRow(symbol: "sparkles", title: L("account.card.plans"), trailing: nil,
                                  external: true) { openBilling(.plans) }
            case .billingPortal:
                AskAccountLinkRow(symbol: "creditcard", title: L("account.card.manage"),
                                  trailing: L("account.card.manageHint"), external: true) {
                    openBilling(.billingPortal)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func openBilling(_ destination: AccountStatusPresentation.Destination) {
        guard !openingBilling else { return }
        billingError = nil
        openingBilling = true
        Task {
            defer { openingBilling = false }
            do {
                let url = try await AccountBillingFlow.destination(
                    for: destination,
                    requestBillingPageToken: { try await auth.requestBillingPageToken() },
                    createPortalSession: { try await auth.createBillingPortalSession() }
                )
                // Coming back from the browser should show the new plan right away.
                auth.invalidateAccountSummary()
                NSWorkspace.shared.open(url)
                onDismiss()
            } catch {
                billingError = error.localizedDescription
            }
        }
    }
}

struct AskAccountProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AskAccountTone.chip)
                Capsule().fill(color).frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct AskAccountLinkRow: View {
    let symbol: String
    let title: String
    let trailing: String?
    let external: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                }
                if external {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AskTheme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
