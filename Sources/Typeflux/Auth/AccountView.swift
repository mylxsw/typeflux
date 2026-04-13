import SwiftUI

struct AccountView: View {
    @ObservedObject var authState: AuthState
    let onLogout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var isPasswordDialogPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if let profile = authState.userProfile {
                profileCard(profile: profile)
            } else if authState.isLoading {
                loadingCard
            } else {
                signedOutCard
            }
        }
        .onAppear {
            Task { await AuthState.shared.refreshTokenIfNeeded() }
        }
        .sheet(isPresented: $isPasswordDialogPresented) {
            ChangePasswordSheet(authState: authState, onPasswordChanged: onLogout)
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

                    if authState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        StudioButton(
                            title: L("auth.account.logout"),
                            systemImage: "rectangle.portrait.and.arrow.forward",
                            variant: .secondary
                        ) {
                            handlePrimaryAction()
                        }
                    }
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
                    isPasswordDialogPresented = true
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudioTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: StudioTheme.BorderWidth.thin)
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

    private func handlePrimaryAction() {
        if authState.isLoggedIn {
            authState.logout()
            onLogout()
        } else {
            LoginWindowController.shared.show()
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
    @State private var changePasswordMessage: String?
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

            if let changePasswordMessage {
                Text(changePasswordMessage)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.accent)
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
        changePasswordMessage = nil
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
                    changePasswordMessage = L("auth.account.passwordChanged")
                    currentPassword = ""
                    newPassword = ""
                    confirmNewPassword = ""
                    authState.logout()
                    onPasswordChanged()
                    dismiss()
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
