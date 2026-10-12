import SwiftUI

/// Owns account state, identity, Cloud promotion, and settings access for both sidebars.
/// Signed out, exactly one sign-in action shows: the Cloud card, or a pill once the card is
/// closed or the sidebar is compact. Only the signed-out identity varies: chat offers local
/// mode; settings shows status only.
struct SidebarAccountFooter<SignedOutIdentity: View>: View {
    @ObservedObject var auth: AuthState
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var dismissedAt: Double
    let compact: Bool
    let onSignIn: () -> Void
    let onOpenAccount: () -> Void
    let onOpenSettings: () -> Void
    let signedOutIdentity: SignedOutIdentity

    init(auth: AuthState, compact: Bool, defaults: UserDefaults = .standard,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         @ViewBuilder signedOutIdentity: () -> SignedOutIdentity) {
        self.auth = auth
        self.compact = compact
        self.onSignIn = onSignIn
        self.onOpenAccount = onOpenAccount
        self.onOpenSettings = onOpenSettings
        self.signedOutIdentity = signedOutIdentity()
        _dismissedAt = AppStorage(wrappedValue: 0, AskCloudPromo.dismissedKey, store: defaults)
    }

    private var showsPromo: Bool {
        !compact && !auth.isLoggedIn && AskCloudPromo.isVisible(dismissedAt: dismissedAt)
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
            Rectangle().fill(AskTheme.separator).frame(height: 0.5)
            HStack(spacing: 9) {
                identity.layoutPriority(1)
                Spacer(minLength: 4)
                if !auth.isLoggedIn, !showsPromo {
                    Button(L("ask.cloudPromo.signIn"), action: onSignIn)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                        .help(AskCloudPromo.summary)
                        .accessibilityHint(AskCloudPromo.summary)
                        .accessibilityIdentifier("sidebar.signIn")
                }
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(AskPressableStyle())
                .help(L("sidebar.settingsAccessibility"))
                .accessibilityLabel(L("sidebar.settingsAccessibility"))
                .accessibilityIdentifier("sidebar.accountSettings")
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: auth.isLoggedIn ? 52 : 56)
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
    init(auth: AuthState, compact: Bool, defaults: UserDefaults = .standard,
         onSignIn: @escaping () -> Void, onOpenAccount: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.init(auth: auth, compact: compact, defaults: defaults,
                  onSignIn: onSignIn, onOpenAccount: onOpenAccount, onOpenSettings: onOpenSettings) {
            AskSignedOutIdentity(subtitle: L("ask.local.identity.localMode"),
                                 detail: L("ask.local.identity.localMode"), action: nil)
        }
    }
}
