import SwiftUI
import UIKit

struct ChatSettingsView: View {
    @Bindable var store: ChatStore
    @Bindable var preferences: ChatPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var settingsOpenFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ChatAccountView(store: store)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 36)).foregroundStyle(ChatTheme.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account").font(.headline)
                                Text(store.email).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .accessibilityIdentifier("settings.account")
                }
                .listRowBackground(ChatTheme.card)

                Section("Appearance") {
                    appearanceChoices
                }
                .listRowBackground(ChatTheme.card)

                Section {
                    Button(action: openSystemSettings) {
                        HStack(spacing: 10) {
                            Label("Language", systemImage: "globe")
                            Spacer(minLength: 8)
                            Text(ChatSettingsInfo.languageName()).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.language")
                    .accessibilityHint("Change the app language in iOS Settings.")
                } footer: {
                    Text("Change the app language in iOS Settings.")
                }
                .listRowBackground(ChatTheme.card)

                Section("About") {
                    LabeledContent("Version", value: ChatSettingsInfo.version)
                        .accessibilityIdentifier("settings.version")
                    Link(destination: ChatSettingsInfo.privacyURL) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings.privacy")
                }
                .listRowBackground(ChatTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.root")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .alert("Unable to open Settings", isPresented: $settingsOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Open the Settings app and choose Typeflux to change its language.")
            }
        }
        .tint(ChatTheme.accent)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onChange(of: store.isAuthenticated) { _, authenticated in
            if !authenticated {
                dismiss()
            }
        }
    }

    private var appearanceChoices: some View {
        HStack(spacing: 4) {
            ForEach(ChatAppearance.allCases) { appearance in
                let selected = appearance == preferences.appearance
                Button { preferences.appearance = appearance } label: {
                    Text(appearance.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : ChatTheme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected ? ChatTheme.card : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance." + appearance.rawValue)
            }
        }
        .padding(4)
        .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appearance")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            settingsOpenFailed = true
            return
        }
        openURL(url) { accepted in settingsOpenFailed = !accepted }
    }
}

struct ChatAccountView: View {
    @Bindable var store: ChatStore
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email").font(.caption).foregroundStyle(.secondary)
                    Text(store.email)
                        .font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.email")
                }
                .padding(.vertical, 6)
                LabeledContent("Status") {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(ChatTheme.accentText)
                        .accessibilityIdentifier("account.status")
                }
            }
            .listRowBackground(ChatTheme.card)

            Section {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account.signOut")
            } footer: {
                Text(
                    "Signing out removes this account from this device. Your cloud conversations stay in your account."
                )
            }
            .listRowBackground(ChatTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background(ChatTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.root")
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign out of Typeflux?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                .accessibilityIdentifier("account.confirmSignOut")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("account.cancelSignOut")
        } message: {
            Text("You'll need to sign in again to access your conversations.")
        }
    }
}
