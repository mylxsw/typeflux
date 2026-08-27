import AppKit
import SwiftUI

struct AccountView: View {
    @ObservedObject var authState: AuthState
    let onLogout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var passwordChangeFlow = PasswordChangeFlow()
    @State private var isOpeningBilling = false
    @State private var billingActionError: String?
    @State private var isHoveringSubscriptionCard = false
    @State private var isHoveringUsageCard = false
    @ObservedObject private var cloudDataSync = CloudDataSyncCoordinator.shared
    @State private var isConfirmingCloudSync = false
    @State private var isConfirmingCloudDataDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if let profile = authState.userProfile {
                profileCard(profile: profile)
                cloudDataSyncCard
                if authState.subscription.shouldShowSubscriptionDetails || authState.subscriptionError != nil {
                    subscriptionCard
                }
                usageCard
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

    private var cloudDataSyncCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                StudioSettingRow(
                    title: L("cloudDataSync.title"),
                    subtitle: L("cloudDataSync.subtitle")
                ) {
                    Toggle("", isOn: Binding(
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
                }

                if cloudDataSync.isEnabled || cloudDataSync.lastError != nil {
                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                    HStack {
                        Text(cloudDataSyncStatus)
                            .font(.studioBody(StudioTheme.Typography.caption))
                            .foregroundStyle(
                                cloudDataSync.lastError == nil ? StudioTheme.textSecondary : StudioTheme.danger
                            )
                        Spacer()
                        if cloudDataSync.isEnabled {
                            StudioButton(
                                title: L("cloudDataSync.syncNow"), systemImage: "arrow.triangle.2.circlepath",
                                variant: .secondary, isDisabled: cloudDataSync.isSyncing,
                                isLoading: cloudDataSync.isSyncing
                            ) { cloudDataSync.synchronizeNow() }
                        }
                    }
                }

                if cloudDataSync.canDeleteCloudData {
                    Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                    Button {
                        isConfirmingCloudDataDeletion = true
                    } label: {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            if cloudDataSync.isDeletingCloudData { ProgressView().controlSize(.small) }
                            Text(L("cloudDataSync.delete.action"))
                        }
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.danger)
                    }
                    .buttonStyle(.plain)
                    .disabled(cloudDataSync.isDeletingCloudData || cloudDataSync.isSyncing)
                }
            }
        }
    }

    private var cloudDataSyncStatus: String {
        if cloudDataSync.isSyncing { return L("cloudDataSync.status.syncing") }
        if let error = cloudDataSync.lastError { return L("cloudDataSync.status.failed", error) }
        if let date = cloudDataSync.lastSyncAt {
            return L("cloudDataSync.status.lastSync", date.formatted(date: .omitted, time: .shortened))
        }
        return L("cloudDataSync.status.waiting")
    }

    private var subscriptionCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                        Text(L("auth.account.subscription"))
                            .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        Spacer()

                        HStack(spacing: StudioTheme.Spacing.small) {
                            AccountRefreshIconButton(
                                helpText: L("auth.account.refreshSubscription"),
                                isVisible: isHoveringSubscriptionCard,
                                isDisabled: authState.isLoadingSubscription
                                    || authState.isSyncingSubscription
                                    || isOpeningBilling,
                                isLoading: authState.isLoadingSubscription
                            ) {
                                Task { await authState.refreshSubscription() }
                            }

                            StudioButton(
                                title: subscriptionPresentation.billingAction == .manageBilling
                                    ? L("auth.account.manageBilling")
                                    : L("auth.account.subscribe"),
                                systemImage: "arrow.up.forward.app",
                                variant: .primary,
                                isDisabled: isOpeningBilling || authState.isSyncingSubscription,
                                isLoading: isOpeningBilling
                            ) {
                                openBillingFlow()
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.medium) {
                        Text(L(subscriptionPresentation.subtitleKey))
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: StudioTheme.Spacing.medium)

                        if subscriptionPresentation.showsSubscriptionSyncAction {
                            subscriptionSyncButton
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                    accountSummaryItem(
                        label: L("auth.account.subscriptionPlan"),
                        value: localized(subscriptionPresentation.plan),
                        systemImage: "creditcard"
                    )

                    accountSummaryItem(
                        label: L("auth.account.subscriptionStatus"),
                        value: localized(subscriptionPresentation.status),
                        systemImage: "checkmark.seal"
                    )

                    accountSummaryItem(
                        label: L(subscriptionPresentation.periodLabelKey),
                        value: localized(subscriptionPresentation.period),
                        systemImage: "calendar.badge.clock"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let error = billingActionError ?? authState.subscriptionError {
                    Text(error)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onHover { isHoveringSubscriptionCard = $0 }
    }

    private var subscriptionPresentation: AccountSubscriptionPresentation {
        AccountSubscriptionPresentation.make(from: authState.subscription)
    }

    private var subscriptionSyncButton: some View {
        Button(action: syncBillingSubscription) {
            Group {
                if authState.isSyncingSubscription {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L("auth.account.subscriptionSyncAction"))
                }
            }
            .font(.studioBody(StudioTheme.Typography.caption))
            .foregroundStyle(StudioTheme.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(
            authState.isSyncingSubscription
                || authState.isLoadingSubscription
                || isOpeningBilling
        )
    }

    private var usageCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                        Text(L("auth.account.usage"))
                            .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        Spacer()

                        AccountRefreshIconButton(
                            helpText: L("auth.account.refreshUsage"),
                            isVisible: isHoveringUsageCard,
                            isDisabled: authState.isLoadingUsage,
                            isLoading: authState.isLoadingUsage
                        ) {
                            Task { await authState.refreshUsage() }
                        }
                    }

                    Text(usageRangeDescription)
                        .font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AccountUsageCreditProgressView(
                    credits: authState.usageCredits,
                    isFreeAllowance: authState.subscription.treatsCreditsAsFreeAllowance
                )

                HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                    accountSummaryItem(
                        label: L("auth.account.usageAudio"),
                        value: formattedAudioDuration(authState.usageStats.asrAudioDurationMs),
                        systemImage: "waveform"
                    )

                    accountSummaryItem(
                        label: L("auth.account.usageTokens"),
                        value: formattedCount(authState.usageStats.chatTotalTokens),
                        systemImage: "text.bubble"
                    )

                    accountSummaryItem(
                        label: L("auth.account.usageRequests"),
                        value: formattedCount(authState.usageStats.totalRequests),
                        systemImage: "bolt.horizontal"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                    accountSummaryItem(
                        label: L("auth.account.usageTranscripts"),
                        value: formattedCount(authState.usageStats.asrOutputChars),
                        systemImage: "character.cursor.ibeam"
                    )

                    accountSummaryItem(
                        label: L("auth.account.usageAnswers"),
                        value: formattedCount(authState.usageStats.chatOutputChars),
                        systemImage: "quote.bubble"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let error = authState.usageError {
                    Text(error)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onHover { isHoveringUsageCard = $0 }
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
            String(format: L("auth.account.subscriptionRenewsOn"), formattedDate(dateString))
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

    // MARK: - Profile Card

    private func profileCard(profile: UserProfile) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
                HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                    ZStack {
                        Circle()
                            .fill(StudioTheme.accentSoft)
                            .frame(width: 60, height: 60)
                        Text(avatarInitial(from: profile))
                            .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .bold))
                            .foregroundStyle(StudioTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                        Text(profile.resolvedDisplayName)
                            .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        Text(profile.email)
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }

                    Spacer()
                }

                HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                    accountSummaryItem(
                        label: L("auth.account.provider"),
                        value: providerDisplayName(profile.provider),
                        systemImage: "person.crop.circle.badge.checkmark"
                    )

                    accountSummaryItem(
                        label: L("auth.account.memberSince"),
                        value: formattedDate(profile.createdAt),
                        systemImage: "calendar"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if profile.canChangePassword {
                    passwordManagementSection
                }
            }
        }
    }

    private var passwordManagementSection: some View {
        StudioCard(padding: StudioTheme.Spacing.medium) {
            HStack(alignment: .center, spacing: StudioTheme.Spacing.medium) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    Text(L("auth.account.passwordSection"))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    Text(L("auth.account.passwordHint"))
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                StudioButton(
                    title: L("auth.account.changePassword"),
                    systemImage: "key",
                    variant: .secondary
                ) {
                    passwordChangeFlow.presentForm()
                }
            }
        }
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

    private func accountSummaryItem(label: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: systemImage)
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(label)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            Text(value)
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudioTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin
                )
        )
    }

    private func avatarInitial(from profile: UserProfile) -> String {
        let source = profile.resolvedDisplayName
        return String(source.prefix(1)).uppercased()
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "password":
            L("auth.account.providerEmail")
        case "google":
            "Google"
        case "apple":
            "Apple"
        default:
            provider
        }
    }

    private func formattedDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return display.string(from: date)
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return display.string(from: date)
        }
        return dateString
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
    var isVisible = true
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
        .allowsHitTesting(isVisible)
        .opacity(isVisible ? (isDisabled && !isLoading ? 0.45 : 1) : 0)
        .animation(.easeOut(duration: 0.14), value: isVisible)
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
