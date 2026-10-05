import AuthenticationServices
import SwiftUI

/// Welcome: the brand, one sentence and three ways in. Email sign-in is its own page.
struct LoginView: View {
    @Bindable var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var googleSignIn: GoogleSignIn
    @State private var googleTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    init(store: ChatStore) {
        self.store = store
        // Synthetic previews must never open a real identity provider.
        _googleSignIn = State(initialValue: GoogleSignIn(
            clientID: store.isSynthetic ? "" : GoogleSignIn.configuredClientID
        ))
    }

    enum Route: Hashable {
        case email
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                                .accessibilityLabel("Browse first").accessibilityIdentifier("login.close")
                        }
                        if !store.draft.isEmpty || store.imageDataURL != nil {
                            Label(
                                "Your draft is saved. Sign in, then review and send it yourself.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.footnote).foregroundStyle(ChatTheme.secondary).padding(.top, 12)
                        }
                        Spacer(minLength: 12)
                        ChatOrb(size: 132)
                        Text(verbatim: "Typeflux").font(.system(size: 30, weight: .bold)).padding(.top, 28)
                        Text("Ask, look at photos and search the web. Conversations sync with your Mac.")
                            .font(.system(size: 16)).foregroundStyle(ChatTheme.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 300).padding(.top, 10)
                        Spacer(minLength: 40)
                        if let error = store.errorMessage {
                            Text(NSLocalizedString(error, comment: "Sign-in error")).font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center).padding(.bottom, 12)
                                .accessibilityIdentifier("login.error")
                        }
                        VStack(spacing: 12) {
                            SignInWithAppleButton(.continue) { request in
                                request.requestedScopes = [.email, .fullName]
                            } onCompletion: { result in
                                handleApple(result)
                            }
                            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                            .frame(height: 52)
                            .clipShape(Capsule())
                            .disabled(store.isLoading)
                            .accessibilityIdentifier("login.apple")
                            Button {
                                googleTask = Task { await store.loginWithGoogle(using: googleSignIn) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image("GoogleMark").resizable().scaledToFit().frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text("Continue with Google").font(.system(size: 16.5, weight: .semibold))
                                }
                                .foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 52)
                                .chatCard(corner: 26)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isLoading)
                            .accessibilityIdentifier("login.google")
                            Button { path.append(.email) } label: {
                                Label("Sign in with email", systemImage: "envelope")
                                    .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .chatCard(corner: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("login.email.open")
                            .disabled(store.isLoading)
                            Button("Browse first") { dismiss() }.accessibilityIdentifier("login.browse")
                            legal.padding(.top, 8)
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .background { ChatAmbientBackground() }
            .overlay {
                if store.isLoading, path.isEmpty {
                    ProgressView().controlSize(.large)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onDisappear {
                // Successful sign-in replaces this view while the initial history is still loading.
                if !store.isAuthenticated {
                    googleTask?.cancel()
                }
                googleTask = nil
            }
            .navigationDestination(for: Route.self) { _ in
                ChatEmailLoginView(store: store)
            }
        }
    }

    private var legal: some View {
        Text(
            "By continuing you agree to the [Terms of Service](https://typeflux.app/terms) and [Privacy Policy](https://typeflux.app/privacy)."
        )
        .font(.system(size: 11.5)).foregroundStyle(ChatTheme.tertiary)
        .tint(ChatTheme.secondary)
        .multilineTextAlignment(.center)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        guard store.showsLogin else { return }
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                store.errorMessage = "Apple sign-in did not return an identity token."
                return
            }
            Task { await store.loginWithApple(identityToken: token, email: credential.email) }
        case let .failure(error):
            // Closing the Apple sheet is a choice, not an error.
            if (error as? ASAuthorizationError)?.code != .canceled {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

struct ChatEmailLoginView: View {
    @Bindable var store: ChatStore
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var showReset = false
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sign in with email").font(.system(size: 30, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Use your Typeflux account. Credits and conversations are shared with your Mac.")
                    .font(.system(size: 15)).foregroundStyle(ChatTheme.secondary).padding(.top, 8)
                VStack(spacing: 0) {
                    field(label: "Email", identifier: "login.email") {
                        TextField("", text: $email, prompt: Text(verbatim: "name@example.com"))
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.next).onSubmit { focusedField = .password }
                    }
                    Rectangle().fill(ChatTheme.separator).frame(height: 0.5)
                    field(label: "Password", identifier: "login.password") {
                        SecureField("Enter your password", text: $password)
                            .textContentType(.password).focused($focusedField, equals: .password)
                            .submitLabel(.go).onSubmit(signIn)
                    }
                }
                .disabled(isBusy)
                .chatCard(corner: 18)
                .padding(.top, 28)
                if let error = store.errorMessage {
                    Text(NSLocalizedString(error, comment: "Sign-in error")).font(.footnote).foregroundStyle(.red)
                        .padding(.top, 10).padding(.horizontal, 4)
                        .accessibilityIdentifier("login.error")
                }
                Button(action: signIn) {
                    Group {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign in").font(.system(size: 16.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(canSubmit || isBusy ? ChatTheme.accent : ChatTheme.accent.opacity(0.4), in: Capsule())
                    .shadow(color: canSubmit ? ChatTheme.accent.opacity(0.35) : .clear, radius: 9, y: 5)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.top, 22)
                .accessibilityIdentifier("login.submit")
                Button("Forgot password?") { showReset = true }
                    .font(.system(size: 14.5, weight: .medium)).foregroundStyle(ChatTheme.accentText)
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
                    .accessibilityIdentifier("login.forgot")
            }
            .padding(.horizontal, 24).padding(.top, 20)
            .frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { ChatAmbientBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.errorMessage = nil
            focusedField = .email
        }
        .sheet(isPresented: $showReset) {
            ChatPasswordResetView(store: store, email: email)
        }
    }

    private func field(label: LocalizedStringKey, identifier: String,
                       @ViewBuilder input: () -> some View) -> some View {
        input().font(.system(size: 16.5)).frame(minHeight: 32)
            .accessibilityLabel(Text(label)).accessibilityIdentifier(identifier)
            .padding(.horizontal, 16).padding(.vertical, 12)
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

/// Two steps on one sheet: send a code to the email, then set a new password.
struct ChatPasswordResetView: View {
    @Bindable var store: ChatStore
    @State var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var codeSent = false
    @State private var finished = false
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    private var canSubmit: Bool {
        if working {
            return false
        }
        if codeSent {
            return !code.trimmingCharacters(in: .whitespaces).isEmpty && newPassword.count >= 8
        }
        return email.contains("@")
    }

    var body: some View {
        NavigationStack {
            Form {
                if finished {
                    Label("Your password has been reset. Sign in with the new password.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(ChatTheme.success)
                        .accessibilityIdentifier("reset.done")
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(codeSent)
                            .accessibilityIdentifier("reset.email")
                        if codeSent {
                            TextField("Verification code", text: $code)
                                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                                .accessibilityIdentifier("reset.code")
                            SecureField("New password (at least 8 characters)", text: $newPassword)
                                .textContentType(.newPassword)
                                .accessibilityIdentifier("reset.password")
                        }
                    } footer: {
                        Text(codeSent ? LocalizedStringKey("Enter the code we emailed you and choose a new password.")
                            : LocalizedStringKey("We'll email you a verification code."))
                    }
                    if let error = store.errorMessage {
                        Text(NSLocalizedString(error, comment: "Reset error")).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? LocalizedStringKey("Done") : LocalizedStringKey("Cancel")) { dismiss() }
                }
                if !finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(codeSent ? LocalizedStringKey("Reset") : LocalizedStringKey("Send code"),
                               action: submit)
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("reset.submit")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { store.errorMessage = nil }
    }

    private func submit() {
        working = true
        Task {
            if codeSent {
                finished = await store.resetPassword(email: email, code: code, newPassword: newPassword)
            } else {
                codeSent = await store.requestPasswordReset(email: email)
            }
            working = false
        }
    }
}
