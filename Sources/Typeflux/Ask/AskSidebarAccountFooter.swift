import SwiftUI

/// Shared account chrome for the chat and settings sidebars.
struct AskSidebarAccountFooter<Identity: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var dismissedAt: Double
    let signedIn: Bool
    let compact: Bool
    let onSignIn: () -> Void
    let onOpenSettings: () -> Void
    let identity: Identity

    init(signedIn: Bool, compact: Bool, defaults: UserDefaults = .standard,
         onSignIn: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         @ViewBuilder identity: () -> Identity) {
        self.signedIn = signedIn
        self.compact = compact
        self.onSignIn = onSignIn
        self.onOpenSettings = onOpenSettings
        self.identity = identity()
        _dismissedAt = AppStorage(wrappedValue: 0, AskCloudPromo.dismissedKey, store: defaults)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !compact, !signedIn, AskCloudPromo.isVisible(dismissedAt: dismissedAt) {
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
            .frame(height: signedIn ? 52 : 56)
        }
        .accessibilityIdentifier("sidebar.accountFooter")
    }
}
