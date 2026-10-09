import SwiftUI
import TypefluxChat
import UIKit

struct ChatSettingsView: View {
    @Bindable var store: ChatStore
    @Bindable var preferences: ChatPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var settingsOpenFailed = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.isAuthenticated {
                        accountCard
                    } else {
                        Button("Sign in") { dismiss(); store.showsLogin = true }
                            .buttonStyle(.borderedProminent).padding().accessibilityIdentifier("settings.login")
                    }
                    sectionLabel("Data and privacy")
                    group {
                        if store.isAuthenticated {
                            NavigationLink { ChatPrivacySettings(store: store) } label: {
                                row(symbol: "checkmark.shield.fill", tint: ChatTheme.accent, title: "AI data sharing") {
                                    Text(store.hasAIConsent ? "Consent granted" : "Consent not granted").font(.caption)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("settings.aiPrivacy")
                        }
                        Link(destination: URL(string: "https://typeflux.app/terms")!) {
                            row(symbol: "doc.text.fill", tint: .gray, title: "Terms of Service") { EmptyView() }
                        }
                        Link(destination: URL(string: "https://typeflux.app/feedback")!) {
                            row(symbol: "bubble.left.fill", tint: .orange, title: "Contact and feedback") { EmptyView()
                            }
                        }
                    }
                    sectionLabel("General")
                    group {
                        ViewThatFits(in: .horizontal) {
                            row(
                                symbol: "moon.fill",
                                tint: Color(red: 0.35, green: 0.34, blue: 0.84),
                                title: "Appearance"
                            ) {
                                appearanceChoices
                            }
                            VStack(alignment: .trailing, spacing: 0) {
                                row(symbol: "moon.fill", tint: Color(red: 0.35, green: 0.34, blue: 0.84),
                                    title: "Appearance") { EmptyView() }
                                appearanceChoices.padding(.horizontal, 16).padding(.bottom, 12)
                            }
                        }
                        divider
                        Button(action: openSystemSettings) {
                            row(symbol: "globe", tint: ChatTheme.accent, title: "Language") {
                                HStack(spacing: 5) {
                                    Text(ChatSettingsInfo.languageName())
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(ChatTheme.tertiary)
                                }
                                .foregroundStyle(ChatTheme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.language")
                        .accessibilityHint("Change the app language in iOS Settings.")
                    }
                    group {
                        Link(destination: ChatSettingsInfo.privacyURL) {
                            row(symbol: "hand.raised.fill", tint: Color(red: 0.2, green: 0.78, blue: 0.35),
                                title: "Privacy Policy") {
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(ChatTheme.tertiary)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.privacy")
                        divider
                        row(symbol: "info", tint: Color(red: 0.56, green: 0.56, blue: 0.58), title: "Version") {
                            Text(ChatSettingsInfo.version).foregroundStyle(ChatTheme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.version")
                    }
                    if store.isAuthenticated {
                        group {
                            Button { confirmingSignOut = true } label: {
                                Text("Sign out").font(.system(size: 16, weight: .medium)).foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account.signOut")
                        }
                        Text(
                            "Signing out removes this account from this device. Your cloud conversations stay in your account."
                        )
                        .font(.system(size: 12.5)).foregroundStyle(ChatTheme.tertiary)
                        .padding(.horizontal, 16)
                        NavigationLink("Delete account") { ChatDeleteAccountView(store: store) }
                            .foregroundStyle(.red).padding().accessibilityIdentifier("settings.deleteAccount")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(ChatTheme.background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.root")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("settings.done")
                }
            }
            .alert("Unable to open Settings", isPresented: $settingsOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Open the Settings app and choose Typeflux to change its language.")
            }
            .alert("Sign out of Typeflux?", isPresented: $confirmingSignOut) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                    .accessibilityIdentifier("account.confirmSignOut")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("account.cancelSignOut")
            } message: {
                Text("You'll need to sign in again to access your conversations.")
            }
        }
        .tint(ChatTheme.accent)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .task { await store.refreshAccountDetails() }
        .onChange(of: store.isAuthenticated) { _, authenticated in
            if !authenticated {
                dismiss()
            }
        }
    }

    // MARK: Account and credits

    private var accountCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ChatAccountView(store: store)
            } label: {
                HStack(spacing: 14) {
                    ChatAvatar(initials: store.initials, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(store.displayName).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary).lineLimit(1)
                            if let plan = store.planLabel {
                                ChatPlanBadge(label: plan, paid: store.creditUsage?.paid == true)
                            }
                        }
                        Text(store.email).font(.system(size: 13.5)).foregroundStyle(ChatTheme.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.tertiary)
                }
                .padding(16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.account")
            if let usage = store.creditUsage {
                Rectangle().fill(ChatTheme.separator).frame(height: 0.5)
                ChatCreditSummary(usage: usage).padding(16)
            }
        }
        .chatCard(corner: 20)
    }

    // MARK: Building blocks

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(ChatTheme.secondary)
            .padding(.horizontal, 16).padding(.top, 10)
    }

    private func group(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0, content: content).chatCard(corner: 20)
    }

    private var divider: some View {
        Rectangle().fill(ChatTheme.separator).frame(height: 0.5).padding(.leading, 57)
    }

    private func row(symbol: String, tint: Color, title: LocalizedStringKey,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 16)).foregroundStyle(.primary).fixedSize()
            Spacer(minLength: 8)
            trailing().font(.system(size: 15))
        }
        .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
    }

    private var appearanceChoices: some View {
        HStack(spacing: 2) {
            ForEach(ChatAppearance.allCases) { appearance in
                let selected = appearance == preferences.appearance
                Button { preferences.appearance = appearance } label: {
                    Text(appearance.shortTitle)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11).frame(minHeight: 30)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatTheme.card)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appearance.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance." + appearance.rawValue)
            }
        }
        .padding(2)
        .background(ChatTheme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

/// "This month's credits", the remaining amount, a meter and the reset date.
struct ChatCreditSummary: View {
    let usage: ChatCreditUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Credits this month").font(.system(size: 13)).foregroundStyle(ChatTheme.secondary)
                Spacer()
                Text(String(format: NSLocalizedString("Resets %@", comment: "Credit period end"),
                            usage.periodEnd.formatted(.dateTime.month(.defaultDigits).day())))
                    .font(.system(size: 12.5)).foregroundStyle(ChatTheme.tertiary)
            }
            if usage.credits.unlimited {
                Text("Unlimited").font(.system(size: 26, weight: .bold)).padding(.top, 4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(usage.credits.remaining.formatted()).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text(verbatim: "/ " + usage.credits.limit.formatted())
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(ChatTheme.secondary)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.credits")
            }
            if let fraction = usage.usedFraction {
                GeometryReader { geometry in
                    Capsule().fill(ChatTheme.fill)
                        .overlay(alignment: .leading) {
                            Capsule().fill(LinearGradient(
                                colors: [ChatTheme.accent, Color(red: 0.55, green: 0.36, blue: 0.96)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geometry.size.width * max(0, 1 - fraction))
                        }
                }
                .frame(height: 6).padding(.top, 12).padding(.bottom, 8)
                .accessibilityHidden(true)
            }
            if let addon = usage.addonRemaining {
                HStack(alignment: .firstTextBaseline) {
                    Text("Add-on credits").font(.system(size: 13)).foregroundStyle(ChatTheme.secondary)
                    Spacer()
                    Text(addon.formatted()).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.addonCredits")
            }
            Text("Shared with your Mac").font(.system(size: 12)).foregroundStyle(ChatTheme.tertiary)
        }
    }
}

struct ChatAccountView: View {
    @Bindable var store: ChatStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    accountRow("Name", value: store.displayName, identifier: "account.name")
                    divider
                    accountRow("Email", value: store.email, identifier: "account.email", selectable: true)
                    divider
                    accountRow("Status", value: NSLocalizedString("Signed in", comment: "Account status"),
                               identifier: "account.status")
                    if let plan = store.planLabel {
                        divider
                        accountRow("Plan", value: plan, identifier: "account.plan")
                    }
                }
                .chatCard(corner: 20)
                if let usage = store.creditUsage {
                    ChatCreditSummary(usage: usage).padding(16).chatCard(corner: 20)
                }
            }
            .padding(16).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(ChatTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.root")
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var divider: some View {
        Rectangle().fill(ChatTheme.separator).frame(height: 0.5).padding(.horizontal, 16)
    }

    private func accountRow(_ title: LocalizedStringKey, value: String, identifier: String,
                            selectable: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).fixedSize()
                Spacer(minLength: 12)
                valueText(value, identifier: identifier, selectable: selectable).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                valueText(value, identifier: identifier, selectable: selectable)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body).padding(16)
    }

    @ViewBuilder private func valueText(_ value: String, identifier: String, selectable: Bool) -> some View {
        if selectable {
            Text(value).foregroundStyle(ChatTheme.secondary).textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        } else {
            Text(value).foregroundStyle(ChatTheme.secondary).accessibilityIdentifier(identifier)
        }
    }
}
