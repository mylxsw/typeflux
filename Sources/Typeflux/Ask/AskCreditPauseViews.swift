import AppKit
import SwiftUI

/// "Credits used up" for a run the server paused at a known checkpoint: monthly
/// and add-on credits side by side, then buy / upgrade, or Continue once the
/// balance is back. Stop stays in the composer.
struct AskCreditPauseCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var localization = AppLocalization.shared
    let presentation: AskCreditPausePresentation
    var working = false
    var errorMessage: String?
    var perform: (AskCreditPausePresentation.Action) -> Void = { _ in }

    private var available: Bool { presentation.state == .available }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol
            VStack(alignment: .leading, spacing: 0) {
                Text(L(presentation.titleKey))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.top, 5)
                Text(bodyText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 4)
                balances.padding(.top, 12)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.danger)
                        .padding(.top, 8)
                }
                if presentation.primary != nil || working {
                    buttons.padding(.top, 14)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AskTheme.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(available ? StudioTheme.success.opacity(0.32) : StudioTheme.warning.opacity(0.32)))
        .transaction {
            if reduceMotion {
                $0.animation = nil; $0.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.creditPause")
    }

    private var bodyText: String {
        let key = presentation.bodyKey
        guard key == "ask.credits.exhausted.waitUntilBody", let end = presentation.periodEnd else { return L(key) }
        return L(key, AccountStatusText.shortDate(end, locale: localization.locale))
    }

    private var symbol: some View {
        Image(systemName: available ? "checkmark" : "pause.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(available ? StudioTheme.success : StudioTheme.warning)
            .frame(width: 32, height: 32)
            .background(available ? AskTheme.successSoft : AskTheme.warningSoft,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private var balances: some View {
        HStack(spacing: 8) {
            column(L("ask.credits.monthly"), presentation.monthlyRemaining)
            column(L("ask.credits.addon"), presentation.addonRemaining)
        }
    }

    private func column(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textTertiary)
            Text(value.map(AccountUsageDisplayFormatter.creditAmount) ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(value == 0 ? StudioTheme.textSecondary : StudioTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AskAccountTone.chip))
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttonRow }
            VStack(alignment: .leading, spacing: 8) { buttonRow }
        }
        .disabled(working)
    }

    @ViewBuilder private var buttonRow: some View {
        if working {
            ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
        }
        if let primary = presentation.primary {
            Button { perform(primary) } label: {
                HStack(spacing: 6) {
                    Image(systemName: AskCreditPausePresentation.symbol(primary))
                        .font(.system(size: 11, weight: .semibold))
                    Text(L(AskCreditPausePresentation.titleKey(primary)))
                }
            }
            .buttonStyle(AskCapsuleButtonStyle())
            .accessibilityIdentifier("ask.creditPause.primary")
        }
        if let secondary = presentation.secondary {
            Button(L(AskCreditPausePresentation.titleKey(secondary))) { perform(secondary) }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityIdentifier("ask.creditPause.secondary")
        }
    }
}

/// Hosts the card for the selected conversation: keeps the balance fresh while the
/// run waits (on appear, when Typeflux is active again, after returning from the
/// billing page) and turns the card's buttons into billing pages or `resume`.
struct AskCreditPauseSection: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var auth: AuthState
    @State private var openingBilling = false
    @State private var billingError: String?

    private var presentation: AskCreditPausePresentation? {
        guard let value = model.selected else { return nil }
        return AskCreditPausePresentation(
            run: value.run, busy: model.busyIds.contains(value.id), credits: auth.usageCredits,
            details: model.creditPauseDetails[value.id], subscription: auth.subscription,
            usagePeriodEnd: auth.usagePeriodEnd
        )
    }

    var body: some View {
        // A stack, not a Group: its tasks must run even while the card is hidden.
        VStack(spacing: 0) {
            if let presentation {
                AskCreditPauseCard(presentation: presentation, working: openingBilling,
                                   errorMessage: billingError, perform: perform)
            }
        }
        .task(id: model.selected?.run?.id) { await syncBalance() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await syncBalance() }
        }
        .onChange(of: auth.usageCredits) { _ in model.creditBalanceDidChange() }
    }

    /// Only while the selected run waits for credits; never resumes it by itself.
    private func syncBalance() async {
        guard model.selected?.run?.isPausedForCredits == true else { return }
        auth.invalidateAccountSummary()
        await auth.refreshAccountSummary()
    }

    private func perform(_ action: AskCreditPausePresentation.Action) {
        switch action {
        case .continueRun:
            billingError = nil
            model.resumeCreditPause()
        case .buyCredits:
            openBilling(tab: BillingPlansLink.creditsTab)
        case .upgradePlan:
            openBilling(tab: nil)
        }
    }

    private func openBilling(tab: String?) {
        guard !openingBilling else { return }
        billingError = nil
        openingBilling = true
        Task {
            defer { openingBilling = false }
            await AccountBillingFlow.open(
                { try await auth.requestBillingPageToken(tab: tab) },
                onLink: { url in
                    // Coming back from the browser fetches the new balance right away.
                    auth.invalidateAccountSummary()
                    NSWorkspace.shared.open(url)
                },
                onFailure: { error in
                    billingError = error.localizedDescription
                }
            )
        }
    }
}
