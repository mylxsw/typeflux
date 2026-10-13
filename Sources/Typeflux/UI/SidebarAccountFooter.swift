import SwiftUI

/// Both sidebars use one account row. Chat may add its local-mode and settings actions.
struct SidebarAccountFooter<SignedOutIdentity: View>: View {
    @ObservedObject var auth: AuthState
    @ObservedObject private var localization = AppLocalization.shared
    let onSignIn: () -> Void
    let onOpenAccount: () -> Void
    let onOpenSettings: (() -> Void)?
    let signedOutIdentity: SignedOutIdentity
    private let showsSignedOutIdentity: Bool

    // Keep the existing initializer compatible with callers sharing this component.
    init(auth: AuthState, compact _: Bool, defaults _: UserDefaults = .standard,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil,
         showsSignedOutIdentity: Bool = true,
         @ViewBuilder signedOutIdentity: () -> SignedOutIdentity) {
        self.auth = auth
        self.onSignIn = onSignIn
        self.onOpenAccount = onOpenAccount
        self.onOpenSettings = onOpenSettings
        self.signedOutIdentity = signedOutIdentity()
        self.showsSignedOutIdentity = showsSignedOutIdentity
    }

    var body: some View {
        HStack(spacing: 8) {
            if auth.isLoggedIn {
                AskAccountFooterIdentity(auth: auth, name:
                    AskPresentation.accountName(name: auth.userProfile?.name, email: auth.userProfile?.email)
                        ?? L("sidebar.appName"), onOpenAccount: onOpenAccount)
            } else {
                if showsSignedOutIdentity {
                    signedOutIdentity.layoutPriority(1)
                    Spacer(minLength: 0)
                    TypefluxIconButton(L("ask.cloudPromo.signIn"), systemImage: "person.crop.circle.badge.plus",
                                       action: onSignIn)
                        .accessibilityIdentifier("sidebar.signIn")
                } else {
                    signIn
                }
            }
            if let onOpenSettings {
                TypefluxIconButton(L("sidebar.settingsAccessibility"), systemImage: "gearshape",
                                   action: onOpenSettings)
                    .accessibilityIdentifier("sidebar.accountSettings")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityIdentifier("sidebar.accountFooter")
        .environment(\.locale, localization.locale)
    }

    private var signIn: some View {
        Button(action: onSignIn) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").font(.title2)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                Text(L("ask.cloudPromo.signIn")).font(.headline)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("auth.account.signedOutSubtitle"))
        .accessibilityLabel(L("ask.cloudPromo.signIn"))
        .accessibilityIdentifier("sidebar.signIn")
    }
}

extension SidebarAccountFooter where SignedOutIdentity == AskSignedOutIdentity {
    init(auth: AuthState, compact: Bool, defaults: UserDefaults = .standard,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil) {
        self.init(auth: auth, compact: compact, defaults: defaults,
                  onSignIn: onSignIn, onOpenAccount: onOpenAccount, onOpenSettings: onOpenSettings,
                  showsSignedOutIdentity: false) {
            AskSignedOutIdentity(detail: L("ask.local.identity.localMode"), action: nil)
        }
    }
}
