import SwiftUI

struct LoginView: View {
    enum Step {
        case enterEmail
        case login
        case register
        case activate
    }

    @StateObject private var authState = AuthState.shared
    @State private var step: Step = .enterEmail
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var name = ""
    @State private var activationCode = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @ObservedObject private var localization = AppLocalization.shared

    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: StudioTheme.Spacing.none) {
            // Header
            VStack(spacing: StudioTheme.Spacing.xSmall) {
                TypefluxLogoBadge()

                Text(L("auth.login.title"))
                    .font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(stepSubtitle)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            .padding(.bottom, StudioTheme.Spacing.section)

            // Form content
            VStack(spacing: StudioTheme.Spacing.medium) {
                switch step {
                case .enterEmail:
                    enterEmailForm
                case .login:
                    loginForm
                case .register:
                    registerForm
                case .activate:
                    activateForm
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.danger)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Back button for non-initial steps
            if step != .enterEmail {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        goBack()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: StudioTheme.Typography.caption, weight: .medium))
                        Text(L("auth.login.back"))
                            .font(.studioBody(StudioTheme.Typography.body))
                    }
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, StudioTheme.Spacing.section)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.windowBackground)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Step Subtitle

    private var stepSubtitle: String {
        switch step {
        case .enterEmail:
            L("auth.login.enterEmailSubtitle")
        case .login:
            L("auth.login.loginSubtitle")
        case .register:
            L("auth.login.registerSubtitle")
        case .activate:
            L("auth.login.activateSubtitle")
        }
    }

    // MARK: - Enter Email Form

    private var enterEmailForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: $email,
                icon: "envelope",
            )

            loginButton(title: L("auth.login.continue"), action: checkEmail)
        }
    }

    // MARK: - Login Form

    private var loginForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            LoginTextField(
                placeholder: L("auth.field.password"),
                text: $password,
                icon: "lock",
                isSecure: true,
            )

            loginButton(title: L("auth.login.signIn"), action: performLogin)
        }
    }

    // MARK: - Register Form

    private var registerForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            LoginTextField(
                placeholder: L("auth.field.name"),
                text: $name,
                icon: "person",
            )

            LoginTextField(
                placeholder: L("auth.field.password"),
                text: $password,
                icon: "lock",
                isSecure: true,
            )

            LoginTextField(
                placeholder: L("auth.field.confirmPassword"),
                text: $confirmPassword,
                icon: "lock.rotation",
                isSecure: true,
            )

            loginButton(title: L("auth.login.createAccount"), action: performRegister)
        }
    }

    // MARK: - Activate Form

    private var activateForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            Text(L("auth.login.activateHint", email))
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)

            LoginTextField(
                placeholder: L("auth.field.activationCode"),
                text: $activationCode,
                icon: "number",
            )

            loginButton(title: L("auth.login.activate"), action: performActivate)
        }
    }

    // MARK: - Shared Button

    private func loginButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                } else {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                    .fill(StudioTheme.accent),
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // MARK: - Actions

    private func checkEmail() {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("auth.error.emailRequired")
            return
        }
        errorMessage = nil
        isLoading = true

        Task {
            do {
                let response = try await AuthAPIService.enterEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
                isLoading = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = response.exists ? .login : .register
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performLogin() {
        guard !password.isEmpty else {
            errorMessage = L("auth.error.passwordRequired")
            return
        }
        errorMessage = nil
        isLoading = true

        Task {
            do {
                let response = try await AuthAPIService.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password,
                )
                await authState.handleLoginSuccess(token: response.accessToken, expiresAt: response.expiresAt, refreshToken: response.refreshToken)
                isLoading = false
                onDismiss()
            } catch let error as AuthError {
                isLoading = false
                if error.authErrorCode == "AUTH_USER_NOT_ACTIVE" {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .activate
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performRegister() {
        guard !password.isEmpty else {
            errorMessage = L("auth.error.passwordRequired")
            return
        }
        guard password == confirmPassword else {
            errorMessage = L("auth.error.passwordMismatch")
            return
        }
        guard password.count >= 8 else {
            errorMessage = L("auth.error.passwordTooShort")
            return
        }
        errorMessage = nil
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.register(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password,
                    name: name.isEmpty ? nil : name,
                )
                isLoading = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .activate
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performActivate() {
        guard !activationCode.isEmpty else {
            errorMessage = L("auth.error.codeRequired")
            return
        }
        errorMessage = nil
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.activate(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: activationCode.trimmingCharacters(in: .whitespacesAndNewlines),
                )
                // Auto-login after activation
                let loginResponse = try await AuthAPIService.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password,
                )
                await authState.handleLoginSuccess(
                    token: loginResponse.accessToken,
                    expiresAt: loginResponse.expiresAt,
                    refreshToken: loginResponse.refreshToken
                )
                isLoading = false
                onDismiss()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func goBack() {
        errorMessage = nil
        switch step {
        case .enterEmail:
            break
        case .login, .register:
            password = ""
            confirmPassword = ""
            step = .enterEmail
        case .activate:
            activationCode = ""
            step = .register
        }
    }
}

// MARK: - Login Text Field

private struct LoginTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    var isSecure: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .disabled(isDisabled)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .disabled(isDisabled)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.surfaceMuted),
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin),
        )
        .opacity(isDisabled ? 0.6 : 1)
    }
}
