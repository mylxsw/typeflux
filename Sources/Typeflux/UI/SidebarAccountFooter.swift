import SwiftUI

/// Owns account state and identity for both sidebars; Cloud features live on the account page.
/// Chat supplies a settings action; the settings window uses its navigation menu instead.
/// Signed out, one compact sign-in action leaves room for the full identity and status.
/// Legacy callers can opt into the dismissible promotion; Chat offers local-mode details.
struct SidebarAccountFooter<SignedOutIdentity: View>: View {
    @ObservedObject var auth: AuthState
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var dismissedAt: Double
    let compact: Bool
    /// Library windows can keep promotion on the account page while reusing the identity row.
    let showsPromotion: Bool
    let onSignIn: () -> Void
    let onOpenAccount: () -> Void
    let onOpenSettings: (() -> Void)?
    let signedOutIdentity: SignedOutIdentity

    init(auth: AuthState, compact: Bool, defaults: UserDefaults = .standard, showsPromotion: Bool = false,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil,
         @ViewBuilder signedOutIdentity: () -> SignedOutIdentity) {
        self.auth = auth
        self.compact = compact
        self.showsPromotion = showsPromotion
        self.onSignIn = onSignIn
        self.onOpenAccount = onOpenAccount
        self.onOpenSettings = onOpenSettings
        self.signedOutIdentity = signedOutIdentity()
        _dismissedAt = AppStorage(wrappedValue: 0, AskCloudPromo.dismissedKey, store: defaults)
    }

    private var showsPromo: Bool {
        showsPromotion && !compact && !auth.isLoggedIn && AskCloudPromo.isVisible(dismissedAt: dismissedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPromo {
                AskCloudPromoCard(onSignIn: onSignIn, onDismiss: {
                    withAnimation(AskMotion.revealAnimation(reduceMotion: reduceMotion)) {
                        dismissedAt = Date().timeIntervalSince1970
                    }
                })
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
            Rectangle().fill(TypefluxColor.separator.color).frame(height: 0.5)
            HStack(spacing: 9) {
                identity.layoutPriority(1)
                Spacer(minLength: 4)
                if !auth.isLoggedIn, !showsPromo {
                    TypefluxButton(kind: .borderless, action: onSignIn) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.body)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .accessibilityLabel(L("ask.cloudPromo.signIn"))
                    .help(L("ask.cloudPromo.signIn") + " · " + AskCloudPromo.summary)
                    .accessibilityHint(AskCloudPromo.summary)
                    .accessibilityIdentifier("sidebar.signIn")
                }
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape").font(.body)
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(AskPressableStyle())
                    .help(L("sidebar.settingsAccessibility"))
                    .accessibilityLabel(L("sidebar.settingsAccessibility"))
                    .accessibilityIdentifier("sidebar.accountSettings")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: auth.isLoggedIn ? 52 : 56)
        }
        .accessibilityIdentifier("sidebar.accountFooter")
        .environment(\.locale, localization.locale)
    }

    @ViewBuilder
    private var identity: some View {
        if auth.isLoggedIn {
            AskAccountFooterIdentity(auth: auth, name:
                AskPresentation.accountName(name: auth.userProfile?.name, email: auth.userProfile?.email)
                    ?? L("sidebar.appName"), onOpenAccount: onOpenAccount)
        } else {
            signedOutIdentity
        }
    }
}

extension SidebarAccountFooter where SignedOutIdentity == AskSignedOutIdentity {
    init(auth: AuthState, compact: Bool, defaults: UserDefaults = .standard, showsPromotion: Bool = false,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil) {
        self.init(auth: auth, compact: compact, defaults: defaults, showsPromotion: showsPromotion,
                  onSignIn: onSignIn, onOpenAccount: onOpenAccount, onOpenSettings: onOpenSettings) {
            AskSignedOutIdentity(subtitle: L("ask.local.identity.localMode"),
                                 detail: L("ask.local.identity.localMode"), action: nil)
        }
    }
}
