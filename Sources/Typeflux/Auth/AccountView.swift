import AppKit
import SwiftUI

struct AccountView: View {
    @ObservedObject var authState: AuthState
    let onLogout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var passwordChangeFlow = PasswordChangeFlow()
    @State private var isOpeningBilling = false
    @State private var billingActionError: String?
    @ObservedObject private var cloudDataSync = CloudDataSyncCoordinator.shared
    @State private var isConfirmingCloudSync = false
    @State private var isConfirmingCloudDataDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if let profile = authState.userProfile {
                profileSummary(profile: profile)
                accountOverview
                cloudDataSyncSection
            } else if authState.isLoading {
                loadingCard
            } else {
                signedOutCard
            }
        }
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
        .alert(L("cloudDataSync.consent.title"), isPresented: $isConfirmingCloudSync) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("cloudDataSync.consent.merge")) {
                cloudDataSync.setEnabled(true, mergeGuestData: true)
            }
            Button(L("cloudDataSync.consent.cloudOnly")) {
                cloudDataSync.setEnabled(true, mergeGuestData: false)
            }
        } message: {
            Text(L("cloudDataSync.consent.message"))
        }
        .alert(L("cloudDataSync.delete.title"), isPresented: $isConfirmingCloudDataDeletion) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("cloudDataSync.delete.confirm"), role: .destructive) {
                cloudDataSync.deleteCloudData()
            }
        } message: {
            Text(L("cloudDataSync.delete.message"))
        }
    }

    private var cloudDataSyncSection: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.large) {
                Text(L("cloudDataSync.title"))
                    .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: StudioTheme.Spacing.large)

                Toggle(L("cloudDataSync.title"), isOn: Binding(
                    get: { cloudDataSync.isEnabled },
                    set: { enabled in
                        if enabled && cloudDataSync.requiresInitialChoice {
                            isConfirmingCloudSync = true
                        } else if enabled {
                            cloudDataSync.setEnabled(true)
                        } else {
                            cloudDataSync.setEnabled(false)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(StudioTheme.accent)
            }

            Text(L("cloudDataSync.accountDescription"))
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = cloudDataSync.lastError, !cloudDataSync.isSyncing {
                Text(L("cloudDataSync.status.failed", error))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.large) {
                cloudDataSyncStatus
                Spacer(minLength: StudioTheme.Spacing.medium)
                if cloudDataSync.canDeleteCloudData {
                    cloudDataManagementMenu
                }
            }
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
    }

    private var cloudDataSyncStatus: some View {
        HStack(spacing: StudioTheme.Spacing.xSmall) {
            if cloudDataSync.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(L("cloudDataSync.status.syncing"))
            }
            if let date = cloudDataSync.lastSyncAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(L(
                        "cloudDataSync.status.lastSyncAgo",
                        AccountDateDisplayFormatter.relativeTime(
                            since: date, now: context.date, locale: localization.locale
                        )
                    ))
                    .monospacedDigit()
                }
            } else if cloudDataSync.isEnabled || cloudDataSync.isSyncing {
                Text(L(cloudDataSync.isSyncing ? "cloudDataSync.status.syncing" : "cloudDataSync.status.waiting"))
            }
        }
        .font(.studioBody(StudioTheme.Typography.bodySmall))
        .foregroundStyle(StudioTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cloudDataManagementMenu: some View {
        Menu {
            Button(role: .destructive) {
                isConfirmingCloudDataDeletion = true
            } label: {
                Label(L("cloudDataSync.delete.action"), systemImage: "trash")
            }
            .disabled(cloudDataSync.isDeletingCloudData || cloudDataSync.isSyncing)
        } label: {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                if cloudDataSync.isDeletingCloudData {
                    ProgressView().controlSize(.mini)
                }
                Text(L("cloudDataSync.manageData"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.Typography.iconTiny, weight: .medium))
            }
            .foregroundStyle(StudioTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(L("cloudDataSync.manageData"))
    }

    private var accountOverview: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
                subscriptionHeader

                AccountUsageCreditProgressView(
                    credits: authState.usageCredits,
                    isFreeAllowance: authState.subscription.treatsCreditsAsFreeAllowance,
                    periodDescription: usageRangeDescription
                )

                usageDetails
            }
        }
    }

    private var showsSubscriptionDetails: Bool {
        authState.subscription.shouldShowSubscriptionDetails || authState.subscriptionError != nil
    }

    private var subscriptionHeader: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: StudioTheme.Spacing.medium) {
                            subscriptionTitle
                            if showsSubscriptionDetails { subscriptionStatus }
                        }
                        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                            subscriptionTitle
                            if showsSubscriptionDetails { subscriptionStatus }
                        }
                    }

                    if showsSubscriptionDetails {
                        Text(localized(subscriptionPresentation.period))
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    AccountRefreshIconButton(
                        helpText: L("auth.account.refreshOverview"),
                        isDisabled: authState.isLoadingSubscription || authState.isLoadingUsage
                            || authState.isSyncingSubscription || isOpeningBilling,
                        isLoading: authState.isLoadingSubscription || authState.isLoadingUsage,
                        action: refreshAccountOverview
                    )

                    if showsSubscriptionDetails {
                        StudioButton(
                            title: L(subscriptionPresentation.billingAction == .manageBilling
                                ? "auth.account.manageBilling" : "auth.account.subscribe"),
                            systemImage: nil,
                            variant: .primary,
                            isDisabled: isOpeningBilling || authState.isSyncingSubscription,
                            isLoading: isOpeningBilling,
                            action: openBillingFlow
                        )
                    }
                }
            }

            if showsSubscriptionDetails, !authState.subscription.entitled {
                Text(L(subscriptionPresentation.subtitleKey))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if subscriptionPresentation.showsSubscriptionSyncAction {
                subscriptionSyncButton
            }
            if let error = billingActionError ?? authState.subscriptionError {
                Text(error)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subscriptionTitle: some View {
        Text(showsSubscriptionDetails
            ? "\(L("sidebar.accountCard.cloudAccount")) · \(localized(subscriptionPresentation.plan))"
            : L("sidebar.accountCard.cloudAccount"))
            .font(.studioBody(StudioTheme.Typography.cardTitle, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subscriptionStatus: some View {
        HStack(spacing: StudioTheme.Spacing.xxSmall) {
            Circle()
                .fill(authState.subscription.entitled ? StudioTheme.success : StudioTheme.textSecondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(localized(subscriptionPresentation.status))
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L("auth.account.subscriptionStatus")): \(localized(subscriptionPresentation.status))")
    }

    private var subscriptionPresentation: AccountSubscriptionPresentation {
        AccountSubscriptionPresentation.make(from: authState.subscription)
    }

    private var subscriptionSyncButton: some View {
        Button(action: syncBillingSubscription) {
            Group {
                if authState.isSyncingSubscription {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("auth.account.subscriptionSyncAction"))
                }
            }
            .font(.studioBody(StudioTheme.Typography.bodySmall))
            .foregroundStyle(StudioTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(authState.isSyncingSubscription || authState.isLoadingSubscription || isOpeningBilling)
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(minimum: 100), spacing: StudioTheme.Spacing.mediumLarge, alignment: .leading
                    ),
                    count: 5
                ),
                alignment: .leading,
                spacing: StudioTheme.Spacing.mediumLarge
            ) {
                usageMetric(
                    label: L("auth.account.usageAudio"),
                    value: formattedAudioDuration(authState.usageStats.asrAudioDurationMs)
                )
                usageMetric(
                    label: L("auth.account.usageTokens"), value: formattedCount(authState.usageStats.chatTotalTokens)
                )
                usageMetric(
                    label: L("auth.account.usageRequests"), value: formattedCount(authState.usageStats.totalRequests)
                )
                usageMetric(
                    label: L("auth.account.usageTranscripts"),
                    value: formattedCount(authState.usageStats.asrOutputChars)
                )
                usageMetric(
                    label: L("auth.account.usageAnswers"), value: formattedCount(authState.usageStats.chatOutputChars)
                )
            }

            if let error = authState.usageError {
                Text(error)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("auth.account.usage"))
    }

    private func usageMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            Text(label)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func localized(_ value: AccountSubscriptionPresentation.TextValue) -> String {
        switch value {
        case let .localized(key):
            L(key)
        case let .literal(text):
            text
        }
    }

    private func localized(_ period: AccountSubscriptionPresentation.PeriodValue) -> String {
        switch period {
        case .unavailable:
            L("auth.account.subscriptionPeriodUnavailable")
        case let .endsOn(dateString):
            String(format: L("auth.account.subscriptionEndsOn"), formattedDate(dateString))
        case let .renewsOn(dateString):
            String(format: L("auth.account.nextRenewal"), formattedDate(dateString))
        case let .cycle(startString, endString):
            if let startString {
                String(
                    format: L("auth.account.subscriptionPeriodRange"),
                    formattedDate(startString),
                    formattedDate(endString)
                )
            } else {
                String(format: L("auth.account.subscriptionPeriodUntil"), formattedDate(endString))
            }
        }
    }

    // MARK: - Profile

    private func profileSummary(profile: UserProfile) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.mediumLarge) {
            Text(avatarInitial(from: profile))
                .font(.studioBody(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 48, height: 48)
                .background(Circle().fill(StudioTheme.accentSoft))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                Text(profile.resolvedDisplayName)
                    .font(.studioBody(StudioTheme.Typography.cardTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text("\(profile.email) · \(providerDisplayName(profile.provider))")
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudioTheme.Spacing.medium)

            if profile.canChangePassword {
                Button(L("auth.account.changePassword")) {
                    passwordChangeFlow.presentForm()
                }
                .buttonStyle(.plain)
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .padding(.vertical, StudioTheme.Spacing.xSmall)
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        StudioCard {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            }
            .frame(height: 120)
        }
    }

    private var signedOutCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                    Text(L("auth.account.signedOutTitle"))
                        .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    Text(L("auth.account.signedOutSubtitle"))
                        .font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                StudioButton(
                    title: L("auth.account.signIn"),
                    systemImage: "person.crop.circle.badge.plus",
                    variant: .primary
                ) {
                    handlePrimaryAction()
                }
            }
        }
    }

    // MARK: - Helpers

    private func avatarInitial(from profile: UserProfile) -> String {
        let source = profile.resolvedDisplayName
        return String(source.prefix(1)).uppercased()
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "password":
            L("auth.account.providerEmail")
        case "google":
            L("auth.account.signedInWith", "Google")
        case "apple":
            L("auth.account.signedInWith", "Apple")
        default:
            provider
        }
    }

    private func formattedDate(_ dateString: String) -> String {
        AccountDateDisplayFormatter.date(dateString, locale: localization.locale)
    }

    private var usageRangeDescription: String {
        guard let start = authState.usagePeriodStart,
              let end = authState.usagePeriodEnd
        else {
            return L("auth.account.usageCycleUnavailable")
        }
        return String(
            format: L("auth.account.usagePeriodHint"),
            formattedDate(start),
            formattedDate(end)
        )
    }

    private func formattedAudioDuration(_ milliseconds: Int64) -> String {
        AccountUsageDisplayFormatter.audioDuration(milliseconds)
    }

    private func formattedCount(_ value: Int64) -> String {
        AccountUsageDisplayFormatter.count(value)
    }

    private func refreshAccountOverview() {
        Task {
            await authState.refreshTokenIfNeeded()
            await authState.refreshSubscription()
            await authState.refreshUsage()
        }
    }

    private func handlePrimaryAction() {
        if authState.isLoggedIn {
            authState.logout()
            onLogout()
        } else {
            LoginWindowController.shared.show()
        }
    }

    private func handlePasswordChangeRelogin() {
        authState.logout()
        passwordChangeFlow.dismiss()
        LoginWindowController.shared.show()
    }

    private func openBillingFlow() {
        billingActionError = nil
        isOpeningBilling = true

        Task {
            do {
                let url = try await AccountBillingFlow.destination(
                    for: subscriptionPresentation.billingAction,
                    requestBillingPageToken: { try await authState.requestBillingPageToken() },
                    createPortalSession: { try await authState.createBillingPortalSession() }
                )
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                    isOpeningBilling = false
                }
            } catch {
                await MainActor.run {
                    isOpeningBilling = false
                    billingActionError = error.localizedDescription
                }
            }
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

private struct ChangePasswordSheet: View {
    @ObservedObject var authState: AuthState
    let onPasswordChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var isChangingPassword = false
    @State private var changePasswordError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                Text(L("auth.account.changePasswordDialogTitle"))
                    .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(L("auth.account.changePasswordDialogSubtitle"))
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                if authState.userProfile?.canChangePassword == true {
                    StudioTextInputCard(
                        label: L("auth.account.currentPassword"),
                        placeholder: L("auth.account.currentPassword"),
                        text: $currentPassword,
                        secure: true
                    )
                }

                StudioTextInputCard(
                    label: L("auth.account.newPassword"),
                    placeholder: L("auth.account.newPassword"),
                    text: $newPassword,
                    secure: true
                )

                StudioTextInputCard(
                    label: L("auth.account.confirmNewPassword"),
                    placeholder: L("auth.account.confirmNewPassword"),
                    text: $confirmNewPassword,
                    secure: true
                )
            }

            if let changePasswordError {
                Text(changePasswordError)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.danger)
            }

            Text(L("auth.account.passwordHint"))
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: StudioTheme.Spacing.small) {
                Spacer()

                StudioButton(
                    title: L("common.cancel"),
                    systemImage: nil,
                    variant: .secondary
                ) {
                    dismiss()
                }

                StudioButton(
                    title: L("auth.account.changePassword"),
                    systemImage: isChangingPassword ? nil : "checkmark",
                    variant: .primary,
                    isDisabled: isChangingPassword,
                    isLoading: isChangingPassword
                ) {
                    changePassword()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func changePassword() {
        changePasswordError = nil

        if authState.userProfile?.canChangePassword == true, currentPassword.isEmpty {
            changePasswordError = L("auth.error.currentPasswordRequired")
            return
        }
        if newPassword.isEmpty {
            changePasswordError = L("auth.error.passwordRequired")
            return
        }
        if newPassword != confirmNewPassword {
            changePasswordError = L("auth.error.passwordMismatch")
            return
        }
        if let passwordError = validatePasswordInput(newPassword) {
            changePasswordError = passwordError
            return
        }
        guard let token = authState.accessToken else {
            changePasswordError = L("auth.error.unauthorized")
            return
        }

        isChangingPassword = true
        Task {
            do {
                _ = try await AuthAPIService.changePassword(
                    token: token,
                    oldPassword: currentPassword,
                    newPassword: newPassword
                )
                await MainActor.run {
                    isChangingPassword = false
                    currentPassword = ""
                    newPassword = ""
                    confirmNewPassword = ""
                    onPasswordChanged()
                }
            } catch {
                await MainActor.run {
                    isChangingPassword = false
                    changePasswordError = error.localizedDescription
                }
            }
        }
    }

    private func validatePasswordInput(_ candidate: String) -> String? {
        guard candidate.count >= 8 else {
            return L("auth.error.passwordTooShort")
        }
        let hasUppercase = candidate.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasLowercase = candidate.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
        return hasUppercase && hasLowercase && hasDigit ? nil : L("auth.error.passwordTooWeak")
    }
}

private struct AccountRefreshIconButton: View {
    let helpText: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioTheme.textSecondary)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: StudioTheme.Typography.iconRegular, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .foregroundStyle(isHovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

private struct PasswordChangeSuccessSheet: View {
    let onRelogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                Text(L("auth.account.passwordChangeSuccessTitle"))
                    .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(L("auth.account.passwordChanged"))
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                StudioButton(
                    title: L("auth.account.relogin"),
                    systemImage: "arrow.clockwise.circle",
                    variant: .primary
                ) {
                    onRelogin()
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
