import SwiftUI

struct AccountView: View {
    @ObservedObject var authState: AuthState
    let onLogout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var isChangingPassword = false
    @State private var changePasswordMessage: String?
    @State private var changePasswordError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            if let profile = authState.userProfile {
                profileCard(profile: profile)
            } else if authState.isLoading {
                loadingCard
            } else {
                signedOutCard
                actionSection
            }
        }
        .onAppear {
            Task { await AuthState.shared.refreshTokenIfNeeded() }
        }
    }

    // MARK: - Profile Card

    private func profileCard(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.section) {
            HStack(spacing: StudioTheme.Spacing.medium) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(StudioTheme.accentSoft)
                        .frame(width: 56, height: 56)
                    Text(avatarInitial(from: profile))
                        .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .bold))
                        .foregroundStyle(StudioTheme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
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
                    actionSection
                }
            }

            // Info rows
            VStack(spacing: StudioTheme.Spacing.small) {
                infoRow(label: L("auth.account.provider"), value: providerDisplayName(profile.provider))
                infoRow(label: L("auth.account.memberSince"), value: formattedDate(profile.createdAt))
            }

            passwordManagementSection(profile: profile)
        }
        .padding(StudioTheme.Spacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.surfaceMuted),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
        )
    }

    @ViewBuilder
    private func passwordManagementSection(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            Divider()
                .padding(.top, 4)

            Text(L("auth.account.passwordSection"))
                .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            if profile.provider == "password" {
                SecureField(L("auth.account.currentPassword"), text: $currentPassword)
                    .textFieldStyle(.roundedBorder)
            }

            SecureField(L("auth.account.newPassword"), text: $newPassword)
                .textFieldStyle(.roundedBorder)

            SecureField(L("auth.account.confirmNewPassword"), text: $confirmNewPassword)
                .textFieldStyle(.roundedBorder)

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

            Button(action: changePassword) {
                HStack(spacing: StudioTheme.Spacing.small) {
                    if isChangingPassword {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(L("auth.account.changePassword"))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isChangingPassword)

            Text(L("auth.account.passwordHint"))
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
        }
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Spacer()
        }
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.surfaceMuted),
        )
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            Text(L("auth.account.signedOutTitle"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)

            Text(L("auth.account.signedOutSubtitle"))
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .padding(StudioTheme.Spacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.surfaceMuted),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
        )
    }

    // MARK: - Action Section

    private var actionSection: some View {
        Button(action: handlePrimaryAction) {
            HStack(spacing: StudioTheme.Spacing.small) {
                Image(systemName: authState.isLoggedIn ? "rectangle.portrait.and.arrow.forward" : "person.crop.circle.badge.plus")
                    .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))

                Text(authState.isLoggedIn ? L("auth.account.logout") : L("auth.account.signIn"))
                    .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
            }
            .foregroundStyle(authState.isLoggedIn ? StudioTheme.textSecondary : StudioTheme.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
        }
        .padding(.vertical, 2)
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
        // Fallback: try without fractional seconds
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

    private func changePassword() {
        changePasswordMessage = nil
        changePasswordError = nil

        if authState.userProfile?.provider == "password", currentPassword.isEmpty {
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
                    onLogout()
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
