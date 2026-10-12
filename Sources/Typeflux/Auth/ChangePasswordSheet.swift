import AppKit
import SwiftUI

struct ChangePasswordSheet: View {
    @ObservedObject var authState: AuthState
    let onPasswordChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var isChangingPassword = false
    @State private var changePasswordError: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text(L("auth.account.changePasswordDialogTitle")).font(.headline)
            TypefluxForm {
                TypefluxFormSection(L("auth.account.changePasswordDialogSubtitle"),
                                    footer: L("auth.account.passwordHint")) {
                    if authState.userProfile?.canChangePassword == true {
                        TypefluxSettingsRow(L("auth.account.currentPassword")) {
                            TypefluxSecureField(L("auth.account.currentPassword"), text: $currentPassword)
                        }
                    }
                    TypefluxSettingsRow(L("auth.account.newPassword")) {
                        TypefluxSecureField(L("auth.account.newPassword"), text: $newPassword)
                    }
                    TypefluxSettingsRow(L("auth.account.confirmNewPassword")) {
                        TypefluxSecureField(L("auth.account.confirmNewPassword"), text: $confirmNewPassword)
                    }
                    if let changePasswordError {
                        Text(changePasswordError).foregroundStyle(TypefluxColor.danger.color)
                    }
                }
            }
            HStack {
                Spacer()
                TypefluxButton(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                TypefluxButton(L("auth.account.changePassword"), kind: .primary) { changePassword() }
                    .disabled(isChangingPassword)
            }
        }
        .padding().frame(width: 520, height: 400)
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
