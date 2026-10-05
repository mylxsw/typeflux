import AuthenticationServices
import SwiftUI
import TypefluxChat

struct ChatConsentView: View {
    @Bindable var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "checkmark.shield.fill").font(.largeTitle).foregroundStyle(ChatTheme.accent)
                    Text("Before sending, review how your data is used").font(.title2.bold())
                    Label(
                        "Your messages, selected photos, dictated text and conversation context are sent to Typeflux to generate and sync replies.",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    if let disclosure = store.disclosure {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AI and tool providers").font(.headline)
                            Text(disclosure.providers.joined(separator: ", "))
                            Text(
                                "These providers may receive the context needed to answer your request, including search queries when web tools are used."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Provider details are unavailable. Try again before sending any content.")
                            .foregroundStyle(.orange)
                        Button("Retry") { Task { await store.loadDisclosure() } }
                    }
                    Text(
                        "You can withdraw consent in Settings. Withdrawal stops new requests; it does not recall data already sent."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    if store.profile == nil {
                        Text("Account details are unavailable. Refresh to continue.").foregroundStyle(.orange)
                        Button("Retry") { Task { await store.refreshAccountDetails() } }
                    }
                    Link("Privacy Policy", destination: ChatSettingsInfo.privacyURL)
                    Button("Agree and continue") { store.acceptAIConsent(); dismiss() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(store.disclosure?.isValid != true || store.profile == nil)
                        .accessibilityIdentifier("privacy.agree")
                    Button("Not now") { store.showsConsent = false; dismiss() }
                        .accessibilityIdentifier("privacy.decline")
                }.padding(24)
            }
            .navigationTitle("AI data sharing").navigationBarTitleDisplayMode(.inline)
        }.presentationDragIndicator(.visible)
    }
}

struct ChatPrivacySettings: View {
    @Bindable var store: ChatStore
    @State private var showConsent = false
    var body: some View {
        Form {
            Section("AI data sharing") {
                Text(store.hasAIConsent ? "Consent granted" : "Consent not granted")
                if let disclosure = store.disclosure {
                    Text(disclosure.providers.joined(separator: ", "))
                }
                Button("Review data sharing") { showConsent = true }
                if store.hasAIConsent {
                    Button("Withdraw consent", role: .destructive) { store.revokeAIConsent() }
                        .accessibilityIdentifier("privacy.revoke")
                }
                Text(
                    "You can withdraw consent in Settings. Withdrawal stops new requests; it does not recall data already sent."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Link("Privacy Policy", destination: ChatSettingsInfo.privacyURL)
                Link("Terms of Service", destination: URL(string: "https://typeflux.app/terms")!)
            }
        }
        .navigationTitle("Data and privacy")
        .task { await store.loadDisclosure() }
        .sheet(isPresented: $showConsent) { ChatConsentView(store: store) }
    }
}

struct ChatDeleteAccountView: View {
    @Bindable var store: ChatStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var password = ""
    @State private var confirmed = false
    @State private var busy = false
    @State private var google = GoogleSignIn(clientID: GoogleSignIn.configuredClientID)

    private var needsApple: Bool {
        store.profile?.providers?.contains("apple") == true
    }

    var body: some View {
        Form {
            Section {
                Label("Permanently delete your account", systemImage: "trash").font(.headline).foregroundStyle(.red)
                Text(
                    "Your account, cloud conversations, photos, memories and sync data will be deleted. All devices will lose account access. This cannot be undone."
                )
                Text(
                    "Website subscriptions will be cancelled immediately. Deletion does not issue a refund. Any App Store subscriptions must be managed separately."
                )
                Link(
                    "Manage App Store subscriptions",
                    destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                )
                Text(
                    "Payment records required for accounting, security logs and previously submitted support reports may be retained under the Privacy Policy. Data already sent to providers is subject to their retention policies."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Toggle("I understand and want to delete my account", isOn: $confirmed)
                    .accessibilityIdentifier("account.delete.confirm")
            }
            if let error = store.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Section("Verify your identity") {
                if needsApple {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = []
                    } onCompletion: { result in
                        if case let .failure(error) = result {
                            if (error as? ASAuthorizationError)?.code != .canceled {
                                store.errorMessage = error.localizedDescription
                            }
                            return
                        }
                        guard case let .success(auth) = result,
                              let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) })
                        else {
                            store.errorMessage = "Apple sign-in did not return an identity token."
                            return
                        }
                        remove(.init(provider: "apple", idToken: token, authorizationCode: code,
                                     clientId: Bundle.main.bundleIdentifier))
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 48).disabled(!confirmed || busy || store.isSynthetic)
                    Text("Continue with Apple to verify and permanently delete this account.").font(.footnote)
                } else {
                    if store.profile?.providers?.contains("password") == true {
                        SecureField("Password", text: $password).textContentType(.password)
                            .accessibilityIdentifier("account.delete.password")
                        Button("Verify and delete account", role: .destructive) {
                            remove(.init(provider: "password", password: password))
                        }.disabled(!confirmed || password.isEmpty || busy)
                            .accessibilityIdentifier("account.delete.submit")
                    }
                    if store.profile?.providers?.contains("google") == true {
                        Button("Verify with Google and delete", role: .destructive) {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    let token = try await google.signIn()
                                    _ = await store.deleteAccount(proof: .init(provider: "google", idToken: token))
                                } catch { store.errorMessage = error.localizedDescription }
                            }
                        }.disabled(!confirmed || busy || store.isSynthetic)
                    }
                    if store.profile?.providers == nil {
                        Text("Account details are unavailable. Refresh to continue.")
                        Button("Retry") { Task { await store.refreshAccountDetails() } }
                    }
                }
                if busy || store.isLoading {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Delete account").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy || store.isLoading)
        .onDisappear { password = "" }
    }

    private func remove(_ proof: ChatDeletionProof) {
        busy = true
        Task {
            _ = await store.deleteAccount(proof: proof)
            password = ""
            busy = false
        }
    }
}

struct ChatReportView: View {
    @Bindable var store: ChatStore
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "Harmful or unsafe content"
    @State private var details = ""
    @State private var busy = false
    @State private var submitted = false
    private let reasons = [
        "Harmful or unsafe content",
        "Incorrect or misleading",
        "Offensive or discriminatory",
        "Other"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(reasons, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                }.pickerStyle(.inline)
                TextField("Additional details (optional)", text: $details, axis: .vertical).lineLimit(3 ... 6)
                Text(
                    "Submitting sends this answer, its identifiers and your explanation to the Typeflux support team. Other messages and photos are not attached."
                )
                .font(.footnote).foregroundStyle(.secondary)
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Report answer").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        busy = true
                        Task {
                            submitted = await store.reportAnswer(message: message, reason: reason, details: details)
                            busy = false
                        }
                    }.disabled(busy).accessibilityIdentifier("report.submit")
                }
            }
            .alert("Report submitted", isPresented: $submitted) { Button("OK") { dismiss() } }
        }.interactiveDismissDisabled(busy)
    }
}
