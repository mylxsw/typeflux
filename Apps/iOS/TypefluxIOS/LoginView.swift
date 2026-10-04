import SwiftUI

struct LoginView: View {
    @Bindable var store: ChatStore
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email, password
    }

    private var isBusy: Bool {
        isSubmitting || store.isLoading
    }

    private var canSubmit: Bool {
        !isBusy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        ChatOrb(size: 88)
                        Text("Ask anything").font(.largeTitle.bold())
                        Text("Your Typeflux conversations, wherever an idea finds you.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .padding(.top, 28)
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Email").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("login.email.label")
                            TextField("", text: $email, prompt: Text(verbatim: "name@example.com"))
                                .textContentType(.username).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next).onSubmit { focusedField = .password }
                                .frame(minHeight: 44)
                                .accessibilityLabel("Email").accessibilityIdentifier("login.email")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("login.password.label")
                            SecureField("Enter your password", text: $password)
                                .textContentType(.password).focused($focusedField, equals: .password)
                                .submitLabel(.go).onSubmit(signIn)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Password").accessibilityIdentifier("login.password")
                        }
                    }
                    .disabled(isBusy)
                    .padding(18).background(ChatTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ChatTheme.border))
                    if let error = store.errorMessage {
                        Text(NSLocalizedString(error, comment: "Sign-in error")).font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if isBusy {
                                ProgressView().tint(.white)
                            } else {
                                Text("Sign in").fontWeight(.semibold)
                            }
                            Spacer()
                        }.padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login.submit")
                    Text("Sign in with an existing Typeflux email and password account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(28).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ChatTheme.background)
            .navigationTitle("Typeflux").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func signIn() {
        guard canSubmit else { return }
        isSubmitting = true
        focusedField = nil
        Task {
            await store.login(email: email, password: password)
            password = ""
            isSubmitting = false
        }
    }
}
