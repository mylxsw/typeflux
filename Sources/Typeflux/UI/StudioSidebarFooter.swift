import SwiftUI

/// Preserves promo dismissal, a single sign-in action, and the existing account hover/click card.
struct StudioSidebarFooter: View {
    @Environment(\.interfaceStyle) private var style
    @ObservedObject var auth = AuthState.shared
    @AppStorage private var dismissedAt: Double
    let compact: Bool
    let onAccountAction: () -> Void

    init(defaults: UserDefaults, compact: Bool, onAccountAction: @escaping () -> Void) {
        self.compact = compact
        self.onAccountAction = onAccountAction
        _dismissedAt = AppStorage(wrappedValue: 0, AskCloudPromo.dismissedKey, store: defaults)
    }

    private var showsPromo: Bool {
        !compact && !auth.isLoggedIn && AskCloudPromo.isVisible(dismissedAt: dismissedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsPromo {
                cloudPromo
            }
            Divider()
            HStack {
                if auth.isLoggedIn {
                    AskAccountFooterIdentity(auth: auth, name: AskPresentation.accountName(
                        name: auth.userProfile?.name, email: auth.userProfile?.email
                    ) ?? L("sidebar.appName"), onOpenAccount: onAccountAction)
                } else {
                    Label(L("ask.local.identity"), systemImage: "person.crop.circle")
                        .font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .lineLimit(1).help(L("ask.local.identity.localMode"))
                    Spacer(minLength: 0)
                    if !showsPromo {
                        TypefluxButton(L("ask.cloudPromo.signIn"), kind: .primary, action: onAccountAction)
                            .help(AskCloudPromo.summary).accessibilityHint(AskCloudPromo.summary)
                            .accessibilityIdentifier("sidebar.signIn")
                    }
                }
            }
            .frame(minHeight: 36)
        }
        .padding(12)
        .accessibilityIdentifier("sidebar.accountFooter")
    }

    private var cloudPromo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Typeflux Cloud", systemImage: "cloud").font(.headline)
                Spacer(minLength: 0)
                TypefluxIconButton(L("ask.cloudPromo.dismiss"), systemImage: "xmark", size: .small) {
                    dismissedAt = Date().timeIntervalSince1970
                }
            }
            ForEach(AskCloudPromo.features, id: \.self) { feature in
                Label(L(feature.key), systemImage: feature.symbol)
                    .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            TypefluxButton(L("ask.cloudPromo.signIn"), kind: .primary, action: onAccountAction)
        }
        .padding(12)
        .background(TypefluxColor.contentBackground.color,
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: style)))
    }
}
