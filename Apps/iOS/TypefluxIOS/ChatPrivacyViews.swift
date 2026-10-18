import AuthenticationServices
import SwiftUI
import TypefluxChat

struct ChatPrivacySettings: View {
    @Bindable var store: ChatStore
    var body: some View {
        Form {
            Section("AI data sharing") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI and tool providers")
                    Text(store.disclosure?.providers.joined(separator: ", ")
                        ?? String(localized: "Provider information is unavailable right now."))
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("privacy.providers")
                Text(
                    "Your messages, selected photos, dictated text and conversation context are sent to Typeflux to generate and sync replies."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Text(
                    "These providers may receive the context needed to answer your request, including search queries when web tools are used."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Link("Privacy Policy", destination: ChatSettingsInfo.privacyURL)
                Link("Terms of Service", destination: ChatSettingsInfo.termsURL)
            }
        }
        .navigationTitle("Data and privacy")
        .task { await store.loadDisclosure() }
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
                VStack(alignment: .leading, spacing: 12) {
                    Label("Permanently delete your account", systemImage: "trash").font(.headline).foregroundStyle(.red)
                    Text(
                        "Your account, cloud conversations, photos, memories and sync data will be deleted. All devices will lose account access. This cannot be undone."
                    )
                    .font(.subheadline)
                }.padding(.vertical, 4)
            }
            Section("Subscriptions and retained records") {
                Text(
                    "Website subscriptions will be cancelled immediately. Deletion does not issue a refund. Any App Store subscriptions must be managed separately."
                ).font(.subheadline)
                Text("Unused purchased credits, including credit packs bought in the App Store, are lost when the account is deleted.")
                    .font(.subheadline)
                Link(
                    "Manage App Store subscriptions",
                    destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                )
                Text(
                    "Payment records required for accounting, security logs and previously submitted support reports may be retained under the Privacy Policy. Data already sent to providers is subject to their retention policies."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Link("Privacy Policy", destination: ChatSettingsInfo.privacyURL)
            }
            if let error = store.errorMessage {
                Text(NSLocalizedString(error, comment: "Error")).foregroundStyle(.red)
            }
            Section("Verify your identity") {
                Toggle("I understand and want to delete my account", isOn: $confirmed)
                    .accessibilityIdentifier("account.delete.confirm")
                Text("Confirm above, then verify your identity to delete the account.")
                    .font(.footnote).foregroundStyle(.secondary)
                if needsApple {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = []
                    } onCompletion: { result in
                        if case let .failure(error) = result {
                            if (error as? ASAuthorizationError)?.code != .canceled {
                                store.errorMessage = ChatStore.userMessage(for: error)
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current password").font(.subheadline.weight(.medium))
                            SecureField("Enter your current password", text: $password).textContentType(.password)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Current password")
                                .accessibilityIdentifier("account.delete.password")
                        }
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
                                } catch { store.errorMessage = ChatStore.userMessage(for: error) }
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
    @State private var reason = ""
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
                Section("Answer being reported") {
                    Text(message.text).font(.subheadline).lineLimit(3)
                        .accessibilityIdentifier("report.answer")
                }
                Section("Reason") {
                    ForEach(Array(reasons.enumerated()), id: \.offset) { index, value in
                        Button { reason = value } label: {
                            HStack {
                                Text(LocalizedStringKey(value)).foregroundStyle(.primary)
                                Spacer(minLength: 12)
                                Image(systemName: "checkmark").foregroundStyle(ChatTheme.accent)
                                    .opacity(reason == value ? 1 : 0).accessibilityHidden(true)
                            }.frame(minHeight: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(reason == value ? .isSelected : [])
                        .accessibilityIdentifier("report.reason.\(index)")
                    }
                }
                Section {
                    TextField("Tell us more (optional)", text: $details, axis: .vertical).lineLimit(3 ... 6)
                        .accessibilityIdentifier("report.details")
                } header: {
                    Text("Additional details (optional)")
                } footer: {
                    Text(
                        "Submitting sends this answer, its identifiers and your explanation to the Typeflux support team. Other messages and photos are not attached."
                    )
                }
                if let error = store.errorMessage {
                    Text(NSLocalizedString(error, comment: "Error")).foregroundStyle(.red)
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
                    }.disabled(busy || reason.isEmpty).accessibilityIdentifier("report.submit")
                }
            }
            .alert("Report submitted", isPresented: $submitted) { Button("OK") { dismiss() } }
        }.interactiveDismissDisabled(busy)
    }
}
