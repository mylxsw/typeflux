import AppKit
import SwiftUI

struct AccountView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var authState: AuthState
    let onLogout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var passwordChangeFlow = PasswordChangeFlow()
    @StateObject var billingLifetime = BillingActionLifetime()
    private var isOpeningBilling: Bool { billingLifetime.isBusy }
    @State private var billingActionError: String?
    // TODO(GUL-57): Cloud data sync is not stable enough for this release. Keep its
    // account-page entry points commented out so the implementation can be restored later.
    // @ObservedObject private var cloudDataSync = CloudDataSyncCoordinator.shared
    // @State private var isConfirmingCloudSync = false
    // @State private var isConfirmingCloudDataDeletion = false
    @State private var isConfirmingLogout = false

    var body: some View {
        TypefluxForm {
            if let profile = authState.userProfile {
                profileSummary(profile: profile)
                planCard
                usageSection
                helpSection
                // TODO(GUL-57): Restore this entry after cloud data sync is ready to ship.
                // cloudDataSyncSection
            } else if authState.isLoading {
                loadingCard
            } else {
                signedOutCard
            }
        }
        .onDisappear { billingLifetime.cancel() }
        .onChange(of: authState.sessionGeneration) { _ in billingLifetime.cancel() }
        .onAppear {
            refreshAccountOverview()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccountOverview()
        }
        .sheet(
            item: Binding(
                get: { passwordChangeFlow.activeDialog },
                set: { dialog in
                    if dialog == nil {
                        passwordChangeFlow.dismiss()
                    }
                }
            )
        ) { dialog in
            switch dialog {
            case .form:
                ChangePasswordSheet(authState: authState) {
                    passwordChangeFlow.showSuccessConfirmation()
                }
            case .successConfirmation:
                PasswordChangeSuccessSheet {
                    handlePasswordChangeRelogin()
                }
            }
        }
        // TODO(GUL-57): Cloud data sync is intentionally hidden for this release because
        // it is not stable enough to ship. Keep these alerts commented out for restoration.
        // .alert(L("cloudDataSync.consent.title"), isPresented: $isConfirmingCloudSync) {
        //     Button(L("common.cancel"), role: .cancel) {}
        //     Button(L("cloudDataSync.consent.merge")) {
        //         cloudDataSync.setEnabled(true, mergeGuestData: true)
        //     }
        //     Button(L("cloudDataSync.consent.cloudOnly")) {
        //         cloudDataSync.setEnabled(true, mergeGuestData: false)
        //     }
        // } message: {
        //     Text(L("cloudDataSync.consent.message"))
        // }
        // .alert(L("cloudDataSync.delete.title"), isPresented: $isConfirmingCloudDataDeletion) {
        //     Button(L("common.cancel"), role: .cancel) {}
        //     Button(L("cloudDataSync.delete.confirm"), role: .destructive) {
        //         cloudDataSync.deleteCloudData()
        //     }
        // } message: {
        //     Text(L("cloudDataSync.delete.message"))
        // }
        .alert(L("auth.account.logoutConfirmTitle"), isPresented: $isConfirmingLogout) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("auth.account.logout"), role: .destructive) {
                authState.logout()
                onLogout()
            }
        } message: {
            Text(L("auth.account.logoutConfirmMessage"))
        }
    }

    // MARK: - Overview

    private var planCard: some View {
        AccountPlanHeroCard(
            authState: authState,
            isOpeningBilling: isOpeningBilling,
            errorMessage: billingActionError ?? authState.subscriptionError,
            onOpenBilling: openBillingFlow,
            onSync: syncBillingSubscription,
            onRefresh: refreshAccountOverview
        )
    }

    private var usageSection: some View {
        TypefluxFormSection(L("account.page.usageSection")) {
            if let start = authState.usagePeriodStart.flatMap(ISO8601DateFormatter.typefluxBillingDate(from:)) {
                Text(L("account.page.usageSince", AccountStatusText.shortDate(start, locale: localization.locale)))
                    .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            AccountUsageMetricsGrid(stats: authState.usageStats, savedMinutes: UsageStatsStore.shared.savedMinutes)
            if let breakdown = authState.usageBreakdown { AccountCreditBreakdownView(breakdown: breakdown) }
        }
    }

    private var helpSection: some View {
        TypefluxFormSection(L("account.page.helpSection")) {
            AccountHelpSection(
                showsSubscriptionSync: AccountSubscriptionPresentation.make(from: authState.subscription)
                    .showsSubscriptionSyncAction,
                showsInvoices: authState.subscription.billingEnabled
                    && (authState.subscription.hasPaidSubscription
                        || AccountStatusPresentation.isPaymentIssue(authState.subscription)),
                isSyncing: authState.isSyncingSubscription,
                onSync: syncBillingSubscription,
                onOpenPortal: { openBillingFlow(.billingPortal) }
            )
        }
    }

    // MARK: - Profile

    private func profileSummary(profile: UserProfile) -> some View {
        TypefluxFormSection(profile.resolvedDisplayName) {
            Text(profileDetail(profile)).textSelection(.enabled)
                .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            HStack {
                if profile.canChangePassword {
                    TypefluxButton(L("auth.account.changePassword")) { passwordChangeFlow.presentForm() }
                }
                TypefluxButton(L("auth.account.logout"), kind: .destructive) { isConfirmingLogout = true }
            }
        }
    }

    /// "email · Signed in with Google · Joined Mar 2026".
    private func profileDetail(_ profile: UserProfile) -> String {
        var parts = [profile.email, AccountStatusText.provider(profile.provider)]
        if let joined = ISO8601DateFormatter.typefluxBillingDate(from: profile.createdAt) {
            let formatter = DateFormatter()
            formatter.locale = localization.locale
            formatter.setLocalizedDateFormatFromTemplate("yMMM")
            parts.append(L("account.page.joined", formatter.string(from: joined)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        TypefluxFormSection(L("account.card.loading")) {
            TypefluxProgress(L("account.card.loading"))
        }
    }

    private var signedOutCard: some View {
        TypefluxFormSection(L("auth.account.signedOutTitle"), footer: L("auth.account.signedOutSubtitle")) {
            TypefluxButton(L("auth.account.signIn"), kind: .primary) { handlePrimaryAction() }
        }
    }

    // MARK: - Helpers

    private func refreshAccountOverview() {
        Task {
            await authState.refreshTokenIfNeeded()
            await authState.refreshSubscription()
            await authState.refreshUsage()
            await authState.refreshUsageBreakdown()
        }
    }

    private func handlePrimaryAction() {
        if authState.isLoggedIn {
            isConfirmingLogout = true
        } else {
            LoginWindowController.shared.show()
        }
    }

    private func handlePasswordChangeRelogin() {
        authState.logout()
        passwordChangeFlow.dismiss()
        LoginWindowController.shared.show()
    }

    private func openBillingFlow(_ destination: AccountStatusPresentation.Destination) {
        guard !isOpeningBilling else { return }
        billingActionError = nil
        billingLifetime.start {
            await AccountBillingFlow.open(
                destination,
                for: authState,
                onLink: { url in
                    authState.invalidateAccountSummary()
                    openURL(url)
                },
                onFailure: { error in
                    billingActionError = error.localizedDescription
                }
            )
        }
    }

    private func syncBillingSubscription() {
        billingActionError = nil
        Task {
            do {
                _ = try await authState.syncSubscription()
            } catch {
                billingActionError = error.localizedDescription
            }
        }
    }
}
